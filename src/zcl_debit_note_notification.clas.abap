*&---------------------------------------------------------------------*
*& Class    : ZCL_DEBIT_NOTE_NOTIFICATION
*& Purpose  : Business orchestrator for the HCB Debit Note e-mail
*&            notification process.
*&
*& Responsibilities (SRP):
*&   1. Receive the posted FI records (from ZCL_MEDICAL_ASSIST_PROCESS)
*&   2. Load ALL employee e-mail addresses in ONE bulk SELECT (PA0105)
*&   3. Group records by PERNR (one e-mail per employee, N rows/employee)
*&   4. Build personalized HTML for each employee (via ZCL_EMAIL_TEMPLATE)
*&   5. Send e-mail per employee (via ZCL_EMAIL_SERVICE)
*&   6. Log every success / failure to BAL (via ZCL_BAL_LOGGER)
*&   7. ALWAYS continue to next employee even if current one fails
*&
*& Error isolation:
*&   Each employee is processed inside its own TRY/CATCH block.
*&   An individual failure (missing e-mail, BCS error, template error)
*&   is logged and the loop advances to the next employee.
*&
*& Performance:
*&   - PA0105 is read once for ALL PERNRs (FOR ALL ENTRIES)
*&   - Employee lookup uses HASHED TABLE → O(1) access
*&   - HTML template is loaded once and reused across all employees
*&---------------------------------------------------------------------*
CLASS zcl_debit_note_notification DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  FRIENDS ltcl_notification_test.

  PUBLIC SECTION.

    " ── Input type: minimal data the notification class needs ──────────
    TYPES:
      BEGIN OF ty_dado_notif,
        pernr        TYPE pernr_d,   " Personnel number (key)
        nome         TYPE ad_name1,  " Employee full name
        natureza     TYPE string,    " Medical cost nature / description
        beneficiario TYPE string,    " Dependent name (or employee name)
        referencia   TYPE string,    " Document reference (shown in subject + header)
        data_doc     TYPE char8,     " Posting date DDMMYYYY (from CSV)
        bukrs        TYPE bukrs,     " Company code
        valor        TYPE dmbtr,     " Total medical service value
        debito       TYPE dmbtr,     " Amount debited to the employee
        waers        TYPE waers_d,   " Currency (default MZN)
      END OF ty_dado_notif,
      tt_dados_notif TYPE STANDARD TABLE OF ty_dado_notif WITH DEFAULT KEY.

    " Inject logger at construction; template and service are created
    " internally (can be replaced via private FOR TESTING methods)
    METHODS constructor
      IMPORTING
        io_logger TYPE REF TO zcl_bal_logger.

    " Main entry point: process all records and send e-mails.
    " Returns number of e-mails successfully sent.
    METHODS process_employees
      IMPORTING
        it_dados       TYPE tt_dados_notif
      RETURNING
        value(rv_sent) TYPE i.

  PRIVATE SECTION.

    " ── Internal types ─────────────────────────────────────────────────
    TYPES:
      BEGIN OF ty_debit_line,
        natureza     TYPE string,
        beneficiario TYPE string,
        valor        TYPE dmbtr,
        debito       TYPE dmbtr,
      END OF ty_debit_line,
      tt_debit_lines TYPE STANDARD TABLE OF ty_debit_line WITH DEFAULT KEY,

      BEGIN OF ty_employee,
        pernr        TYPE pernr_d,
        email        TYPE ad_smtpadr,
        nome         TYPE ad_name1,
        referencia   TYPE string,
        data_doc     TYPE char8,
        bukrs        TYPE bukrs,
        waers        TYPE waers_d,
        lines        TYPE tt_debit_lines,
        total_valor  TYPE dmbtr,
        total_debito TYPE dmbtr,
      END OF ty_employee,
      " HASHED TABLE ensures O(1) lookup by PERNR
      tt_employees TYPE HASHED TABLE OF ty_employee
                   WITH UNIQUE KEY pernr.

    DATA mo_logger   TYPE REF TO zcl_bal_logger.
    DATA mo_template TYPE REF TO zcl_email_template.

    " Template IDs stored as constants — change here without recompile
    " (the actual HTML content lives in ZTMPL_CONTENT, maintainable
    " via SM30 without a transport)
    CONSTANTS:
      c_template_id     TYPE string VALUE 'ZDEBIT_NOTE_HCB',
      c_pa0105_subtype  TYPE subty  VALUE '0010',   " e-mail subtype
      c_email_subject   TYPE string VALUE 'Nota de Débito – Assistência Médica'.

    " ── Private methods ────────────────────────────────────────────────

    " Build the employee HASHED TABLE from the flat input records
    METHODS build_employee_map
      IMPORTING
        it_dados          TYPE tt_dados_notif
      RETURNING
        value(rt_employees) TYPE tt_employees.

    " Load e-mail addresses from PA0105 for all PERNRs in one SELECT
    METHODS load_emails_bulk
      CHANGING
        ct_employees TYPE tt_employees.

    " Build the complete HTML for one employee (calls template)
    METHODS build_employee_html
      IMPORTING
        is_employee    TYPE ty_employee
      RETURNING
        value(rv_html) TYPE string
      RAISING
        zcx_debit_note_error.

    " Build the <tr> rows HTML block for the detail table
    METHODS build_table_rows
      IMPORTING
        it_lines        TYPE tt_debit_lines
        iv_currency     TYPE waers_d
      RETURNING
        value(rv_rows)  TYPE string.

    " Build one <tr> row (alternates background for zebra styling)
    METHODS build_single_row
      IMPORTING
        is_line        TYPE ty_debit_line
        iv_is_even     TYPE abap_bool
        iv_currency    TYPE waers_d
      RETURNING
        value(rv_row)  TYPE string.

    " Format a DMBTR amount into the display currency format (MZN)
    METHODS format_amount
      IMPORTING
        iv_amount      TYPE dmbtr
        iv_currency    TYPE waers_d
      RETURNING
        value(rv_text) TYPE string.

    " Convert posting date from DDMMYYYY (CSV) to DD/MM/YYYY (display)
    METHODS format_date
      IMPORTING
        iv_date_raw    TYPE char8
      RETURNING
        value(rv_text) TYPE string.

    " Send the assembled HTML e-mail to one employee
    METHODS send_employee_email
      IMPORTING
        is_employee TYPE ty_employee
        iv_html     TYPE string
      RAISING
        cx_bcs.

ENDCLASS.


CLASS zcl_debit_note_notification IMPLEMENTATION.

  METHOD constructor.
    mo_logger = io_logger.

    " Load the HTML template once — reused across all employees.
    " replace_variables resets to the raw template each call, so
    " this single instance is safe for the entire run.
    mo_template = NEW zcl_email_template( ).
    TRY.
        mo_template->load_template( c_template_id ).
        mo_logger->log_success(
          |Template '{ c_template_id }' carregado com sucesso.| ).
      CATCH zcx_debit_note_error INTO DATA(lx_tpl).
        " Template failure is critical — log it. process_employees will
        " detect that mo_template has no HTML and skip all employees.
        mo_logger->log_error(
          iv_message = 'Falha ao carregar template HTML'
          iv_detail  = lx_tpl->mv_message ).
        CLEAR mo_template.
    ENDTRY.
  ENDMETHOD.


  METHOD process_employees.
    " Guard: if template failed to load, nothing can be sent
    IF mo_template IS NOT BOUND.
      mo_logger->log_error(
        'Processamento de e-mails cancelado: template HTML não disponível' ).
      RETURN.
    ENDIF.

    " Step 1: group flat records into one entry per employee
    DATA(lt_employees) = build_employee_map( it_dados ).

    " Step 2: load all e-mail addresses in a single DB query
    load_emails_bulk( CHANGING ct_employees = lt_employees ).

    " Step 3: send one HTML e-mail per employee
    LOOP AT lt_employees INTO DATA(ls_emp).
      TRY.
          " Validate e-mail address before attempting to send
          IF ls_emp-email IS INITIAL.
            mo_logger->log_warning(
              |PERNR { ls_emp-pernr }: e-mail não encontrado em PA0105 (subtype { c_pa0105_subtype }). Ignorado.| ).
            CONTINUE.
          ENDIF.

          DATA(lv_html) = build_employee_html( ls_emp ).
          send_employee_email( is_employee = ls_emp  iv_html = lv_html ).
          rv_sent = rv_sent + 1.

          mo_logger->log_success(
            |PERNR { ls_emp-pernr } ({ ls_emp-nome }): e-mail enviado para { ls_emp-email }.| ).

        CATCH zcx_debit_note_error INTO DATA(lx_domain).
          mo_logger->log_error(
            iv_message = |PERNR { ls_emp-pernr }: erro ao construir HTML|
            iv_detail  = lx_domain->mv_message ).

        CATCH cx_bcs INTO DATA(lx_bcs).
          mo_logger->log_error(
            iv_message = |PERNR { ls_emp-pernr }: falha no envio BCS|
            iv_detail  = lx_bcs->get_text( ) ).

        CATCH cx_root INTO DATA(lx_root).
          " Safety net — unexpected exception must not stop the loop
          mo_logger->log_error(
            iv_message = |PERNR { ls_emp-pernr }: erro inesperado|
            iv_detail  = lx_root->get_text( ) ).
      ENDTRY.
    ENDLOOP.

    mo_logger->log_success(
      |Notificação concluída: { rv_sent } e-mail(s) enviado(s) de { lines( lt_employees ) } colaborador(es).| ).
  ENDMETHOD.


  METHOD build_employee_map.
    LOOP AT it_dados INTO DATA(ls_dado).
      " Try to read existing employee entry in the HASHED TABLE
      READ TABLE rt_employees WITH TABLE KEY pernr = ls_dado-pernr
        ASSIGNING FIELD-SYMBOL(<ls_emp>).

      IF sy-subrc <> 0.
        " First occurrence of this PERNR — create the employee entry
        INSERT VALUE ty_employee(
          pernr      = ls_dado-pernr
          nome       = ls_dado-nome
          referencia = ls_dado-referencia
          data_doc   = ls_dado-data_doc
          bukrs      = ls_dado-bukrs
          waers      = COND #( WHEN ls_dado-waers IS INITIAL THEN 'MZN'
                               ELSE ls_dado-waers ) )
          INTO TABLE rt_employees ASSIGNING <ls_emp>.
      ENDIF.

      " Append this record as one line in the employee's detail table
      APPEND VALUE ty_debit_line(
        natureza     = ls_dado-natureza
        beneficiario = ls_dado-beneficiario
        valor        = ls_dado-valor
        debito       = ls_dado-debito )
        TO <ls_emp>-lines.

      " Accumulate totals
      <ls_emp>-total_valor  = <ls_emp>-total_valor  + ls_dado-valor.
      <ls_emp>-total_debito = <ls_emp>-total_debito + ls_dado-debito.
    ENDLOOP.
  ENDMETHOD.


  METHOD load_emails_bulk.
    " Collect distinct PERNRs into a helper table for FOR ALL ENTRIES
    DATA lt_pernrs TYPE SORTED TABLE OF pernr_d WITH UNIQUE KEY table_line.
    LOOP AT ct_employees ASSIGNING FIELD-SYMBOL(<ls_e>).
      INSERT <ls_e>-pernr INTO TABLE lt_pernrs.
    ENDLOOP.

    CHECK lt_pernrs IS NOT INITIAL.

    " Single SELECT for all employees — avoids N RFC calls
    " PA0105 subtype 0010 = business e-mail; confirm subtype in PA30
    SELECT pernr, usrid_long AS email
      FROM pa0105
      FOR ALL ENTRIES IN @lt_pernrs
      WHERE pernr = @lt_pernrs-table_line
        AND subty = @c_pa0105_subtype
        AND endda >= @sy-datum
        AND begda <= @sy-datum
      INTO TABLE @DATA(lt_emails).

    " Map e-mails back to the employee HASHED TABLE (O(1) per entry)
    LOOP AT lt_emails INTO DATA(ls_email).
      READ TABLE ct_employees WITH TABLE KEY pernr = ls_email-pernr
        ASSIGNING FIELD-SYMBOL(<ls_emp>).
      IF sy-subrc = 0 AND <ls_emp>-email IS INITIAL.
        <ls_emp>-email = ls_email-email.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_employee_html.
    " Build the detail table rows for this employee
    DATA(lv_rows) = build_table_rows(
      it_lines    = is_employee-lines
      iv_currency = is_employee-waers ).

    " Assemble all placeholders in one pass
    DATA(lt_ph) = VALUE zcl_email_template=>tt_placeholders(
      ( name = '{{DATA}}'        value = format_date( is_employee-data_doc ) )
      ( name = '{{REF}}'         value = is_employee-referencia )
      ( name = '{{TABLE_ROWS}}'  value = lv_rows )
      ( name = '{{TOTAL_VALOR}}' value = format_amount(
                                           iv_amount   = is_employee-total_valor
                                           iv_currency = is_employee-waers ) )
      ( name = '{{TOTAL_DEBITO}}' value = format_amount(
                                            iv_amount   = is_employee-total_debito
                                            iv_currency = is_employee-waers ) ) ).

    mo_template->replace_variables( lt_ph ).
    rv_html = mo_template->build_html( ).
  ENDMETHOD.


  METHOD build_table_rows.
    DATA lv_index TYPE i VALUE 1.
    LOOP AT it_lines INTO DATA(ls_line).
      DATA(lv_is_even) = COND abap_bool(
        WHEN lv_index MOD 2 = 0 THEN abap_true ELSE abap_false ).
      rv_rows = rv_rows && build_single_row(
        is_line     = ls_line
        iv_is_even  = lv_is_even
        iv_currency = iv_currency ).
      lv_index = lv_index + 1.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_single_row.
    " Zebra-stripe: even rows get the light-lilac HCB colour
    DATA(lv_bg) = COND string(
      WHEN iv_is_even THEN '#f5f5fa' ELSE '#ffffff' ).

    DATA(lv_cell) =
      `style="padding:10px; font-family:Arial,Helvetica,sans-serif;` &&
      ` font-size:13px; color:#333333; background-color:` && lv_bg &&
      `; border-bottom:1px solid #ededf3;"`.

    DATA(lv_cell_r) =
      `style="padding:10px; font-family:Arial,Helvetica,sans-serif;` &&
      ` font-size:13px; color:#333333; background-color:` && lv_bg &&
      `; border-bottom:1px solid #ededf3; text-align:right; white-space:nowrap;"`.

    rv_row =
      `<tr>` &&
      `<td class="tbl-cell" ` && lv_cell && `>` && is_line-natureza     && `</td>` &&
      `<td class="tbl-cell" ` && lv_cell && `>` && is_line-beneficiario && `</td>` &&
      `<td class="tbl-cell" ` && lv_cell_r && `>` &&
        format_amount( iv_amount = is_line-valor  iv_currency = iv_currency ) &&
      `</td>` &&
      `<td class="tbl-cell" ` && lv_cell_r && `>` &&
        format_amount( iv_amount = is_line-debito iv_currency = iv_currency ) &&
      `</td>` &&
      `</tr>`.
  ENDMETHOD.


  METHOD format_amount.
    " Use SAP's built-in currency output formatting.
    " WRITE ... TO CURRENCY formats with the locale's thousand/decimal
    " separators configured for the currency in table TCURX.
    DATA lv_char TYPE char30.
    WRITE iv_amount TO lv_char CURRENCY iv_currency NO-SIGN.
    CONDENSE lv_char.
    rv_text = lv_char && ` ` && iv_currency.
  ENDMETHOD.


  METHOD format_date.
    " Input: DDMMYYYY (raw from CSV, e.g. '29062026')
    " Output: DD/MM/YYYY (display, e.g. '29/06/2026')
    CHECK strlen( iv_date_raw ) = 8.
    rv_text = iv_date_raw(2)   && '/'    " DD
           && iv_date_raw+2(2) && '/'    " MM
           && iv_date_raw+4(4).          " YYYY
  ENDMETHOD.


  METHOD send_employee_email.
    DATA(lo_mail) = NEW zcl_email_service( ).

    lo_mail->create_document(
      iv_subject = |{ c_email_subject } – Ref.: { is_employee-referencia }|
      iv_html    = iv_html ).

    lo_mail->add_recipient(
      iv_email = is_employee-email
      iv_name  = CONV ad_name1( is_employee-nome ) ).

    lo_mail->send( ).
  ENDMETHOD.

ENDCLASS.


*&---------------------------------------------------------------------*
*& Unit Tests for ZCL_DEBIT_NOTE_NOTIFICATION
*& Focus: grouping logic and error isolation (no DB, no e-mail server)
*&---------------------------------------------------------------------*
CLASS ltcl_notification_test DEFINITION FINAL FOR TESTING
  RISK LEVEL HARMLESS
  DURATION SHORT.

  PRIVATE SECTION.
    DATA mo_logger TYPE REF TO zcl_bal_logger.

    METHODS setup.

    " Multiple records for same PERNR must produce one employee entry
    METHODS test_grouping_same_pernr FOR TESTING.

    " Different PERNRs must produce separate employee entries
    METHODS test_grouping_diff_pernr FOR TESTING.

    " Totals must accumulate correctly across multiple lines
    METHODS test_totals_accumulate FOR TESTING.

    " format_date converts DDMMYYYY → DD/MM/YYYY
    METHODS test_format_date FOR TESTING.

    " format_amount must not dump on zero amount
    METHODS test_format_amount_zero FOR TESTING.

ENDCLASS.


CLASS ltcl_notification_test IMPLEMENTATION.

  METHOD setup.
    " Minimal logger — BAL handle will be initial but methods are no-ops
    mo_logger = NEW zcl_bal_logger(
      iv_object    = 'ZTEST'
      iv_subobject = 'UNIT' ).
  ENDMETHOD.


  METHOD test_grouping_same_pernr.
    " Two records for the same employee → one HASHED entry with 2 lines
    DATA(lo_sut) = NEW zcl_debit_note_notification( mo_logger ).

    DATA(lt_input) = VALUE zcl_debit_note_notification=>tt_dados_notif(
      ( pernr = '00001234' nome = 'Ana Costa'
        natureza = 'Consulta' beneficiario = 'Titular'
        referencia = 'REF-001' data_doc = '29062026'
        bukrs = 'HCB' valor = '500' debito = '100' waers = 'MZN' )
      ( pernr = '00001234' nome = 'Ana Costa'
        natureza = 'Medicação' beneficiario = 'Filho'
        referencia = 'REF-001' data_doc = '29062026'
        bukrs = 'HCB' valor = '200' debito = '50'  waers = 'MZN' ) ).

    " Access private method via FRIENDS
    DATA(lt_map) = lo_sut->build_employee_map( lt_input ).

    cl_abap_unit_assert=>assert_equals(
      exp = 1  act = lines( lt_map )
      msg = 'Dois registros do mesmo PERNR devem gerar uma entrada' ).

    READ TABLE lt_map INTO DATA(ls_emp) WITH TABLE KEY pernr = '00001234'.
    cl_abap_unit_assert=>assert_equals(
      exp = 2  act = lines( ls_emp-lines )
      msg = 'Employee deve ter 2 linhas de detalhe' ).
  ENDMETHOD.


  METHOD test_grouping_diff_pernr.
    DATA(lo_sut) = NEW zcl_debit_note_notification( mo_logger ).

    DATA(lt_input) = VALUE zcl_debit_note_notification=>tt_dados_notif(
      ( pernr = '00001111' nome = 'Pedro Neves'
        natureza = 'Consulta' beneficiario = 'Titular'
        referencia = 'REF-001' data_doc = '29062026'
        bukrs = 'HCB' valor = '300' debito = '60' waers = 'MZN' )
      ( pernr = '00002222' nome = 'Maria João'
        natureza = 'Cirurgia' beneficiario = 'Cônjuge'
        referencia = 'REF-001' data_doc = '29062026'
        bukrs = 'HCB' valor = '5000' debito = '1000' waers = 'MZN' ) ).

    DATA(lt_map) = lo_sut->build_employee_map( lt_input ).

    cl_abap_unit_assert=>assert_equals(
      exp = 2  act = lines( lt_map )
      msg = 'PERNRs distintos devem gerar entradas separadas' ).
  ENDMETHOD.


  METHOD test_totals_accumulate.
    DATA(lo_sut) = NEW zcl_debit_note_notification( mo_logger ).

    DATA(lt_input) = VALUE zcl_debit_note_notification=>tt_dados_notif(
      ( pernr = '00009999' nome = 'Luis Fonseca'
        natureza = 'Rx'    beneficiario = 'Titular'
        referencia = 'R1' data_doc = '01062026'
        bukrs = 'HCB' valor = '100' debito = '20' waers = 'MZN' )
      ( pernr = '00009999' nome = 'Luis Fonseca'
        natureza = 'Lab'   beneficiario = 'Titular'
        referencia = 'R1' data_doc = '01062026'
        bukrs = 'HCB' valor = '300' debito = '60' waers = 'MZN' ) ).

    DATA(lt_map) = lo_sut->build_employee_map( lt_input ).

    READ TABLE lt_map INTO DATA(ls_e) WITH TABLE KEY pernr = '00009999'.
    cl_abap_unit_assert=>assert_equals(
      exp = CONV dmbtr( '400' )  act = ls_e-total_valor
      msg = 'total_valor deve ser 400' ).
    cl_abap_unit_assert=>assert_equals(
      exp = CONV dmbtr( '80' )   act = ls_e-total_debito
      msg = 'total_debito deve ser 80' ).
  ENDMETHOD.


  METHOD test_format_date.
    DATA(lo_sut) = NEW zcl_debit_note_notification( mo_logger ).
    DATA(lv_result) = lo_sut->format_date( '29062026' ).

    cl_abap_unit_assert=>assert_equals(
      exp = '29/06/2026'  act = lv_result
      msg = 'DDMMYYYY deve formatar como DD/MM/YYYY' ).
  ENDMETHOD.


  METHOD test_format_amount_zero.
    DATA(lo_sut) = NEW zcl_debit_note_notification( mo_logger ).
    " Must not dump when amount is zero
    DATA(lv_result) = lo_sut->format_amount(
      iv_amount   = CONV dmbtr( '0' )
      iv_currency = 'MZN' ).

    cl_abap_unit_assert=>assert_not_initial(
      act = lv_result
      msg = 'Valor zero deve produzir string não vazia' ).
  ENDMETHOD.

ENDCLASS.
