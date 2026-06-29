*&---------------------------------------------------------------------*
*& Class    : ZCL_BAL_LOGGER
*& Purpose  : Thin wrapper over the SAP Application Log (BAL) API.
*&            Centralises all BAL FM calls so callers work with a
*&            clean interface (log_success / log_warning / log_error).
*&            Log is visible in transaction SLG1.
*&
*& Usage:
*&   DATA(lo_log) = NEW zcl_bal_logger(
*&     iv_object    = 'ZDEBIT_NOTE'
*&     iv_subobject = 'EMAIL_NOTIF'
*&     iv_extnumber = |Run { sy-datum } { sy-uzeit }| ).
*&   lo_log->log_success( 'E-mail enviado para 00001234' ).
*&   lo_log->log_error(   iv_message = 'Falha ao enviar'
*&                        iv_detail  = lx_error->mv_message ).
*&   lo_log->save_log( ).
*&   lo_log->display_log( ).
*&---------------------------------------------------------------------*
CLASS zcl_bal_logger DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    " Creates the in-memory log header. Call once per execution.
    METHODS constructor
      IMPORTING
        iv_object    TYPE balobj_d
        iv_subobject TYPE balsubobj
        iv_extnumber TYPE balnrext OPTIONAL.

    " Severity S — informational success message
    METHODS log_success
      IMPORTING
        iv_message TYPE string.

    " Severity W — warning that does not stop processing
    METHODS log_warning
      IMPORTING
        iv_message TYPE string.

    " Severity E — error for one record; processing continues
    METHODS log_error
      IMPORTING
        iv_message TYPE string
        iv_detail  TYPE string OPTIONAL.

    " Persist the log to database (APPL_LOG table) — call once at end
    METHODS save_log.

    " Display the log in a popup (ALV-based BAL viewer)
    METHODS display_log.

  PRIVATE SECTION.
    DATA mv_log_handle TYPE balloghndl.

    " Internal helper: writes one entry to the in-memory log buffer
    METHODS add_message
      IMPORTING
        iv_type    TYPE symsgty
        iv_message TYPE string.

ENDCLASS.


CLASS zcl_bal_logger IMPLEMENTATION.

  METHOD constructor.
    DATA(ls_log) = VALUE bal_s_log(
      object    = iv_object
      subobject = iv_subobject
      extnumber = iv_extnumber
      aldate    = sy-datum
      altime    = sy-uzeit
      aluser    = sy-uname ).

    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log      = ls_log
      IMPORTING
        e_log_handle = mv_log_handle
      EXCEPTIONS
        log_header_inconsistent = 1
        OTHERS                  = 2.

    " If BAL cannot be initialised (e.g. missing customising), the
    " handle stays initial and subsequent add_message calls will be
    " no-ops (BAL_LOG_MSG_ADD returns subrc <> 0 silently).
  ENDMETHOD.


  METHOD log_success.
    add_message( iv_type = 'S' iv_message = iv_message ).
  ENDMETHOD.


  METHOD log_warning.
    add_message( iv_type = 'W' iv_message = iv_message ).
  ENDMETHOD.


  METHOD log_error.
    " Append detail to the main message when provided
    DATA(lv_full) = COND string(
      WHEN iv_detail IS NOT INITIAL
      THEN |{ iv_message }: { iv_detail }|
      ELSE iv_message ).
    add_message( iv_type = 'E' iv_message = lv_full ).
  ENDMETHOD.


  METHOD save_log.
    CHECK mv_log_handle IS NOT INITIAL.
    DATA(lt_handles) = VALUE bal_t_logh( ( mv_log_handle ) ).

    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_t_log_handle = lt_handles
      EXCEPTIONS
        OTHERS         = 1.
  ENDMETHOD.


  METHOD display_log.
    CHECK mv_log_handle IS NOT INITIAL.
    DATA(lt_handles) = VALUE bal_t_logh( ( mv_log_handle ) ).

    CALL FUNCTION 'BAL_DSP_LOG_DISPLAY'
      EXPORTING
        i_t_log_handle = lt_handles
      EXCEPTIONS
        OTHERS         = 1.
  ENDMETHOD.


  METHOD add_message.
    CHECK mv_log_handle IS NOT INITIAL.

    " SAP message class '00', message '001' outputs the first variable
    " as free text. SYMSGV is char50; longer messages are truncated.
    " For production, replace with a dedicated Z-message class that
    " supports the full message length via MSGV1-V4 (4 x 50 = 200 chars).
    DATA ls_msg TYPE bal_s_msg.
    ls_msg-msgty = iv_type.
    ls_msg-msgid = '00'.
    ls_msg-msgno = '001'.
    ls_msg-msgv1 = CONV symsgv( iv_message ).

    CALL FUNCTION 'BAL_LOG_MSG_ADD'
      EXPORTING
        i_log_handle = mv_log_handle
        i_s_msg      = ls_msg
      EXCEPTIONS
        OTHERS       = 1.
  ENDMETHOD.

ENDCLASS.
