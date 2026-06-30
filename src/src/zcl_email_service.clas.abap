*&---------------------------------------------------------------------*
*& Class    : ZCL_EMAIL_SERVICE
*& Purpose  : Thin wrapper over CL_BCS / CL_DOCUMENT_BCS for sending
*&            HTML e-mails via SAP Business Communication Services.
*&            E-mails are queued in SCOT and dispatched by the mail
*&            send job (RSCONN01 or equivalent).
*&
*& Responsibilities (SRP):
*&   - Create the e-mail document (HTML body + subject)
*&   - Add one or more recipients (internet address)
*&   - Send (enqueue in SCOT) and commit the queue entry
*&
*& Usage — one instance per e-mail:
*&   DATA(lo_mail) = NEW zcl_email_service( ).
*&   lo_mail->create_document(
*&     iv_subject = 'Nota de Débito – Ref. NDH-2026-001'
*&     iv_html    = lv_html ).
*&   lo_mail->add_recipient(
*&     iv_email = 'colaborador@hcb.co.mz'
*&     iv_name  = 'João Silva' ).
*&   DATA(lv_ok) = lo_mail->send( ).
*&
*& Note on COMMIT WORK:
*&   send( ) calls COMMIT WORK to flush the BCS queue entry.
*&   This is safe when called from ENVIAR_EMAILS, because FI documents
*&   have already been committed by CARREGAR_LANCAMENTOS beforehand.
*&---------------------------------------------------------------------*
CLASS zcl_email_service DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    " Prepare the HTML document. Must be called before add_recipient.
    METHODS create_document
      IMPORTING
        iv_subject TYPE string
        iv_html    TYPE string
      RAISING
        cx_bcs.

    " Add an internet recipient. Can be called multiple times (CC/BCC
    " via i_recipient_type on CL_CAM_ADDRESS_BCS if needed).
    METHODS add_recipient
      IMPORTING
        iv_email TYPE ad_smtpadr
        iv_name  TYPE ad_name1 OPTIONAL
      RAISING
        cx_bcs.

    " Enqueue the e-mail in SCOT and commit.
    " Returns abap_true on success, abap_false if send raised CX_BCS
    " (the exception is re-raised so the caller can decide).
    METHODS send
      RETURNING
        value(rv_success) TYPE abap_bool
      RAISING
        cx_bcs.

  PRIVATE SECTION.
    DATA mo_send_request TYPE REF TO cl_bcs.
    DATA mo_document     TYPE REF TO cl_document_bcs.

    " Splits a long HTML string into 255-char BCSY_TEXT lines.
    " CL_DOCUMENT_BCS requires the body as a table of SOLI (char255).
    METHODS html_to_body_lines
      IMPORTING
        iv_html       TYPE string
      RETURNING
        value(rt_lines) TYPE bcsy_text.

ENDCLASS.


CLASS zcl_email_service IMPLEMENTATION.

  METHOD create_document.
    DATA(lt_body) = html_to_body_lines( iv_html ).

    mo_document = cl_document_bcs=>create_document(
      i_type    = 'HTM'         " HTML rendering in e-mail client
      i_subject = iv_subject
      i_text    = lt_body ).

    mo_send_request = cl_bcs=>create_persistent( ).
    mo_send_request->set_document( mo_document ).
  ENDMETHOD.


  METHOD add_recipient.
    " Build a display name like "João Silva <colaborador@hcb.co.mz>"
    " when the name is available; otherwise use plain address.
    DATA(lo_address) = cl_cam_address_bcs=>create_internet_address(
      i_address_string = iv_email
      i_address_name   = iv_name ).

    mo_send_request->add_recipient(
      i_recipient = lo_address
      i_express   = abap_true ).   " abap_true = high-priority delivery
  ENDMETHOD.


  METHOD send.
    " i_with_error_screen = abap_false → propagate cx_bcs to caller
    " instead of showing an interactive error popup (batch-safe)
    mo_send_request->send( i_with_error_screen = abap_false ).

    " Commit the BCS queue entry (scot outbox). FI documents are
    " already committed at this point — this commit only affects BCS.
    COMMIT WORK.

    rv_success = abap_true.
  ENDMETHOD.


  METHOD html_to_body_lines.
    " Slice the HTML string into 255-char chunks.
    " HTML is whitespace-insensitive so splitting at any byte boundary
    " is safe for rendering purposes.
    DATA(lv_remaining) = iv_html.

    WHILE lv_remaining IS NOT INITIAL.
      DATA(lv_len) = strlen( lv_remaining ).
      IF lv_len <= 255.
        APPEND VALUE soli( line = lv_remaining ) TO rt_lines.
        CLEAR lv_remaining.
      ELSE.
        APPEND VALUE soli( line = lv_remaining(255) ) TO rt_lines.
        lv_remaining = lv_remaining+255.
      ENDIF.
    ENDWHILE.
  ENDMETHOD.

ENDCLASS.
