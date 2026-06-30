*&---------------------------------------------------------------------*
*& Class    : ZCL_MEDICAL_ASSIST_PROCESS  (REFACTORED)
*& Purpose  : Coordinator / facade for the HCB Medical Assistance
*&            debit-note loading process.
*&
*& Responsibilities (SRP — coordinator only):
*&   - UPLOAD_DADOS:        read CSV file via GUI_UPLOAD
*&   - VALIDAR_DADOS:       mark invalid records (no aborts)
*&   - CARREGAR_LANCAMENTOS: post FI documents via BAPI
*&   - ENVIAR_EMAILS:        delegate to ZCL_DEBIT_NOTE_NOTIFICATION
*&
*& Changes from original:
*&   [F04] ty_dado defined correctly; 'TESTE' type and MO_SEND removed
*&   [F01-03] MESSAGE 'E' in loops replaced by is_valid flag + BAL log
*&   [F05] GET_EMAIL_FROM_PERNR removed; bulk load in ZCL_DEBIT_NOTE_NOTIFICATION
*&   [F09] Hardcoded year/period/bukrs/ref derived from CSV data
*&   [F17] Hardcoded vendor 0000021670 documented as TODO (business rule)
*&   [F11] Application Log (BAL) via ZCL_BAL_LOGGER for all operations
*&   FI commits: BAPI_TRANSACTION_COMMIT kept per document (SAP standard)
*&---------------------------------------------------------------------*
CLASS zcl_medical_assist_process DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    " ── Data types: CSV row structure ─────────────────────────────────
    " Fields match the tab-separated columns in the input file.
    " Dates are stored as CHAR8 in DDMMYYYY format (as supplied in CSV).
    TYPES:
      BEGIN OF ty_dado,
        pernr        TYPE pernr_d,   " Personnel number
        nome         TYPE ad_name1,  " Employee full name
        natureza     TYPE string,    " Medical cost nature
        beneficiario TYPE string,    " Dependent name
        conta        TYPE saknr,     " G/L account for expense
        centro_custo TYPE kostl,     " Cost centre
        bukrs        TYPE bukrs,     " Company code (e.g. HCB)
        data         TYPE char8,     " Posting date DDMMYYYY
        doc_dat      TYPE char8,     " Document date DDMMYYYY
        valor        TYPE dmbtr,     " Employee debit amount
        val_hcb      TYPE dmbtr,     " HCB portion of cost
        debito       TYPE dmbtr,     " Total debit shown in e-mail
        documento    TYPE char10,    " Assigned FI document number
        referencia   TYPE char20,    " Business reference shown in e-mail
        waers        TYPE waers_d,   " Currency (default MZN)
        " Processing flags — set by VALIDAR_DADOS / CARREGAR_LANCAMENTOS
        is_valid     TYPE abap_bool,
        is_posted    TYPE abap_bool,
        message      TYPE string,    " Validation or posting error detail
      END OF ty_dado,
      tt_dado TYPE STANDARD TABLE OF ty_dado WITH DEFAULT KEY.

    METHODS constructor
      IMPORTING
        iv_file TYPE rlgrap-filename.

    METHODS upload_dados.
    METHODS validar_dados.
    METHODS carregar_lancamentos.
    METHODS enviar_emails.

  PRIVATE SECTION.

    " ── Number range constants (HCB-specific) ─────────────────────────
    CONSTANTS:
      c_nr_range_nr  TYPE inri-nrrangenr VALUE '43',
      c_nr_object    TYPE nrobj          VALUE 'RF_BELEG',
      c_nr_subobject TYPE nrnrs          VALUE 'HCB',
      c_obj_type     TYPE string         VALUE 'ZBKPF',
      c_obj_sys      TYPE string         VALUE 'SAPPRD',
      c_bus_act      TYPE string         VALUE 'RFBU',
      c_doc_type     TYPE blart          VALUE '63',    " Debit note doc type
      c_sp_gl_ind    TYPE string         VALUE 'T',     " Special G/L indicator
      c_alloc_nmbr   TYPE dzuonr         VALUE 'PHINDU',
      " TODO: confirm vendor 0000021670 (HCB clinic master vendor) with FI team
      c_hcb_vendor   TYPE lfa1-lifnr     VALUE '0000021670',
      c_bal_object   TYPE balobj_d       VALUE 'ZDEBIT_NOTE',
      c_bal_subobj   TYPE balsubobj      VALUE 'FI_POST'.

    DATA mv_file        TYPE string.
    DATA mt_dados       TYPE tt_dado.
    DATA mo_logger      TYPE REF TO zcl_bal_logger.
    DATA mo_notificacao TYPE REF TO zcl_debit_note_notification.

    " Convert DDMMYYYY (CSV format) to YYYYMMDD (SAP internal date)
    METHODS csv_date_to_sap
      IMPORTING
        iv_date_raw    TYPE char8
      RETURNING
        value(rv_date) TYPE char8.

    " Extract year from DDMMYYYY (positions 4-7)
    METHODS year_from_csv_date
      IMPORTING
        iv_date_raw    TYPE char8
      RETURNING
        value(rv_year) TYPE char4.

    " Extract period (month) from DDMMYYYY (positions 2-3)
    METHODS period_from_csv_date
      IMPORTING
        iv_date_raw    TYPE char8
      RETURNING
        value(rv_per)  TYPE monat.

ENDCLASS.


CLASS zcl_medical_assist_process IMPLEMENTATION.

  METHOD constructor.
    mv_file = iv_file.

    mo_logger = NEW zcl_bal_logger(
      iv_object    = c_bal_object
      iv_subobject = c_bal_subobj
      iv_extnumber = |Run { sy-datum } { sy-uzeit } { sy-uname }| ).

    " ZCL_DEBIT_NOTE_NOTIFICATION gets the same logger instance so all
    " BAL entries appear in one consolidated log (SLG1 object ZDEBIT_NOTE)
    mo_notificacao = NEW zcl_debit_note_notification( mo_logger ).
  ENDMETHOD.


  METHOD upload_dados.
    " Read the tab-separated CSV file into the structured internal table.
    " E-mail addresses are NOT loaded here — the notification class
    " performs a single bulk SELECT from PA0105 at send time.
    CALL METHOD cl_gui_frontend_services=>gui_upload
      EXPORTING
        filename            = mv_file
        filetype            = 'ASC'
        has_field_separator = abap_true
      CHANGING
        data_tab            = mt_dados
      EXCEPTIONS
        file_open_error     = 1
        file_read_error     = 2
        no_batch            = 3
        gui_refuse_filetransfer = 4
        invalid_type        = 5
        no_authority        = 6
        OTHERS              = 7.

    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_debit_note_error
        EXPORTING iv_message = |Erro ao abrir arquivo: { mv_file }. Subrc = { sy-subrc }|.
    ENDIF.

    " Default currency to MZN when not supplied in CSV
    LOOP AT mt_dados ASSIGNING FIELD-SYMBOL(<ls_dado>).
      IF <ls_dado>-waers IS INITIAL.
        <ls_dado>-waers = 'MZN'.
      ENDIF.
    ENDLOOP.

    mo_logger->log_success(
      |{ lines( mt_dados ) } registro(s) carregado(s) de '{ mv_file }'.| ).
  ENDMETHOD.


  METHOD validar_dados.
    " Mark invalid records with is_valid = abap_false and a message.
    " Processing CONTINUES for all remaining records (no MESSAGE 'E').
    DATA lv_invalid TYPE i.

    LOOP AT mt_dados ASSIGNING FIELD-SYMBOL(<ls>).
      <ls>-is_valid = abap_true.   " Assume valid until a rule fails

      IF <ls>-pernr IS INITIAL.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'PERNR em branco'.
      ELSEIF <ls>-valor <= 0.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'Valor inválido (deve ser > 0)'.
      ELSEIF <ls>-conta IS INITIAL.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'Conta G/L em branco'.
      ELSEIF <ls>-centro_custo IS INITIAL.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'Centro de Custo em branco'.
      ELSEIF <ls>-data IS INITIAL.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'Data de lançamento em branco'.
      ELSEIF <ls>-bukrs IS INITIAL.
        <ls>-is_valid = abap_false.
        <ls>-message  = 'Empresa (bukrs) em branco'.
      ENDIF.

      IF <ls>-is_valid = abap_false.
        lv_invalid = lv_invalid + 1.
        mo_logger->log_warning(
          |Linha { sy-tabix } (PERNR { <ls>-pernr }): { <ls>-message }. Ignorada.| ).
      ENDIF.
    ENDLOOP.

    DATA(lv_valid) = lines( mt_dados ) - lv_invalid.
    mo_logger->log_success(
      |Validação: { lv_valid } válido(s), { lv_invalid } ignorado(s).| ).
  ENDMETHOD.


  METHOD carregar_lancamentos.
    " Post one FI document per valid record.
    " BAPI_TRANSACTION_COMMIT must be called after each posting
    " (SAP standard: one commit per BAPI_ACC_DOCUMENT_POST call).
    DATA lv_posted   TYPE i.
    DATA lv_errors   TYPE i.
    DATA vendor_no   TYPE lfa1-lifnr.

    LOOP AT mt_dados ASSIGNING FIELD-SYMBOL(<ls>).
      " Skip invalid or already-posted records
      CHECK <ls>-is_valid = abap_true AND <ls>-is_posted = abap_false.

      TRY.
          " ── Get next internal document number ───────────────────────
          DATA ld_number TYPE string.
          CALL FUNCTION 'NUMBER_GET_NEXT'
            EXPORTING
              nr_range_nr = c_nr_range_nr
              object      = c_nr_object
              subobject   = c_nr_subobject
              toyear      = year_from_csv_date( <ls>-data )
            IMPORTING
              number      = ld_number
            EXCEPTIONS
              OTHERS      = 1.

          IF sy-subrc <> 0.
            RAISE EXCEPTION TYPE zcx_debit_note_error
              EXPORTING iv_message = 'Falha ao obter número de documento'.
          ENDIF.

          " ── Convert CSV dates to YYYYMMDD (SAP internal) ────────────
          DATA(lv_doc_dat) = csv_date_to_sap( <ls>-doc_dat ).
          DATA(lv_post_dt) = csv_date_to_sap( <ls>-data ).
          DATA(lv_year)    = year_from_csv_date( <ls>-data ).
          DATA(lv_period)  = period_from_csv_date( <ls>-data ).

          " ── Convert PERNR to vendor number format ───────────────────
          " Business rule: HCB employees also exist as vendors.
          " TODO: confirm this mapping is still valid with FI team.
          UNPACK <ls>-pernr TO vendor_no.

          " ── Build BAPI document header ──────────────────────────────
          DATA(ls_header) = VALUE bapiache09(
            doc_type   = c_doc_type
            comp_code  = <ls>-bukrs
            obj_type   = c_obj_type
            username   = sy-uname
            obj_key    = ld_number
            obj_sys    = c_obj_sys
            bus_act    = c_bus_act
            fisc_year  = lv_year
            fis_period = lv_period
            ref_doc_no = <ls>-referencia
            doc_date   = lv_doc_dat
            pstng_date = lv_post_dt
            header_txt = |Assistência Médica - { ld_number }| ).

          " ── G/L account line (expense debit) ────────────────────────
          DATA(lt_gl) = VALUE STANDARD TABLE OF bapiacgl09(
            ( itemno_acc = '0000000001'
              gl_account = <ls>-conta
              item_text  = 'Assistência Médica HCB'
              comp_code  = <ls>-bukrs
              fis_period = lv_period
              fisc_year  = lv_year
              pstng_date = lv_post_dt
              costcenter = <ls>-centro_custo ) ).

          " ── Vendor lines (employee credit + clinic credit) ───────────
          DATA(lt_payable) = VALUE STANDARD TABLE OF bapiacap09(
            " Line 2: employee's portion (amount they owe)
            ( itemno_acc = '0000000002'
              vendor_no  = vendor_no
              comp_code  = <ls>-bukrs
              sp_gl_ind  = c_sp_gl_ind
              alloc_nmbr = c_alloc_nmbr
              item_text  = |Débito Colaborador { <ls>-pernr }| )
            " Line 3: HCB clinic vendor (total offsetting credit)
            " TODO: confirm c_hcb_vendor with FI / confirm business rule
            ( itemno_acc = '0000000003'
              vendor_no  = c_hcb_vendor
              comp_code  = <ls>-bukrs
              alloc_nmbr = c_alloc_nmbr
              item_text  = 'Clínica HCB — Débito Total' ) ).

          " ── Posting keys (extension table) ──────────────────────────
          DATA(lt_ext2) = VALUE STANDARD TABLE OF bapiparex(
            ( structure = 'POSTING_KEY' valuepart1 = '0000000001' valuepart2 = '40' )
            ( structure = 'POSTING_KEY' valuepart1 = '0000000002' valuepart2 = '29' )
            ( structure = 'POSTING_KEY' valuepart1 = '0000000003' valuepart2 = '31' ) ).

          " ── Currency amounts ─────────────────────────────────────────
          DATA(lv_total) = <ls>-val_hcb + <ls>-valor.
          DATA(lt_amounts) = VALUE STANDARD TABLE OF bapiaccr09(
            ( itemno_acc = '0000000001' currency = <ls>-waers amt_doccur =  <ls>-val_hcb )
            ( itemno_acc = '0000000002' currency = <ls>-waers amt_doccur =  <ls>-valor   )
            ( itemno_acc = '0000000003' currency = <ls>-waers amt_doccur = -lv_total     ) ).

          " ── Post document ────────────────────────────────────────────
          DATA lt_return TYPE STANDARD TABLE OF bapiret2.
          CALL FUNCTION 'BAPI_ACC_DOCUMENT_POST'
            EXPORTING  documentheader = ls_header
            TABLES     accountgl      = lt_gl
                       accountpayable = lt_payable
                       currencyamount = lt_amounts
                       extension2     = lt_ext2
                       return         = lt_return.

          " Check for BAPI errors BEFORE committing
          DATA lv_bapi_error TYPE abap_bool.
          LOOP AT lt_return INTO DATA(ls_ret) WHERE type CA 'AE'.
            lv_bapi_error = abap_true.
            mo_logger->log_error(
              iv_message = |PERNR { <ls>-pernr }: falha no lançamento FI|
              iv_detail  = ls_ret-message ).
          ENDLOOP.

          IF lv_bapi_error = abap_false.
            " Commit this document (SAP standard: one commit per BAPI call)
            CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
              EXPORTING wait = abap_true.

            <ls>-is_posted = abap_true.
            <ls>-documento = ld_number.
            lv_posted = lv_posted + 1.
            mo_logger->log_success(
              |PERNR { <ls>-pernr }: documento { ld_number } lançado.| ).
          ELSE.
            " Rollback to leave the system in a consistent state
            CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
            lv_errors = lv_errors + 1.
          ENDIF.

        CATCH zcx_debit_note_error INTO DATA(lx_domain).
          lv_errors = lv_errors + 1.
          <ls>-message = lx_domain->mv_message.
          mo_logger->log_error(
            iv_message = |PERNR { <ls>-pernr }: erro no lançamento|
            iv_detail  = lx_domain->mv_message ).

        CATCH cx_root INTO DATA(lx_root).
          lv_errors = lv_errors + 1.
          mo_logger->log_error(
            iv_message = |PERNR { <ls>-pernr }: erro inesperado no lançamento|
            iv_detail  = lx_root->get_text( ) ).
      ENDTRY.
    ENDLOOP.

    mo_logger->log_success(
      |Lançamentos: { lv_posted } postado(s), { lv_errors } com erro.| ).
  ENDMETHOD.


  METHOD enviar_emails.
    " Build the minimal notification input from the posted records only.
    " Only records with is_posted = abap_true receive an e-mail.
    DATA lt_notif TYPE zcl_debit_note_notification=>tt_dados_notif.

    LOOP AT mt_dados INTO DATA(ls_dado)
      WHERE is_valid = abap_true AND is_posted = abap_true.

      APPEND VALUE zcl_debit_note_notification=>ty_dado_notif(
        pernr        = ls_dado-pernr
        nome         = ls_dado-nome
        natureza     = ls_dado-natureza
        beneficiario = ls_dado-beneficiario
        referencia   = ls_dado-referencia
        data_doc     = ls_dado-data
        bukrs        = ls_dado-bukrs
        valor        = ls_dado-val_hcb + ls_dado-valor  " Total medical value
        debito       = ls_dado-valor                    " Employee's portion
        waers        = ls_dado-waers )
        TO lt_notif.
    ENDLOOP.

    IF lt_notif IS INITIAL.
      mo_logger->log_warning( 'Nenhum registro postado disponível para notificação.' ).
      RETURN.
    ENDIF.

    DATA(lv_enviados) = mo_notificacao->process_employees( lt_notif ).

    mo_logger->log_success(
      |Envio concluído: { lv_enviados } e-mail(s) enfileirado(s) no SCOT.| ).

    " Persist and display the full execution log (SLG1 / BAL)
    mo_logger->save_log( ).
    mo_logger->display_log( ).
  ENDMETHOD.


  METHOD csv_date_to_sap.
    " DDMMYYYY → YYYYMMDD
    CHECK strlen( iv_date_raw ) = 8.
    rv_date = iv_date_raw+4(4)   " YYYY
           && iv_date_raw+2(2)   " MM
           && iv_date_raw(2).    " DD
  ENDMETHOD.


  METHOD year_from_csv_date.
    CHECK strlen( iv_date_raw ) = 8.
    rv_year = iv_date_raw+4(4).
  ENDMETHOD.


  METHOD period_from_csv_date.
    CHECK strlen( iv_date_raw ) = 8.
    rv_per = iv_date_raw+2(2).
  ENDMETHOD.

ENDCLASS.
