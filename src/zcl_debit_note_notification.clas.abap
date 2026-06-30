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
