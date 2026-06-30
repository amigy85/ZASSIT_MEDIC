*&---------------------------------------------------------------------*
*& Class    : ZCX_DEBIT_NOTE_ERROR
*& Purpose  : Domain exception for the Debit Note notification process.
*&            Raised by ZCL_EMAIL_TEMPLATE, ZCL_EMAIL_SERVICE and
*&            ZCL_DEBIT_NOTE_NOTIFICATION for all recoverable errors
*&            that the caller must handle explicitly (cx_static_check).
*&---------------------------------------------------------------------*
CLASS zcx_debit_note_error DEFINITION
  PUBLIC
  INHERITING FROM cx_static_check
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    " Human-readable message — set by the raising code
    DATA mv_message TYPE string READ-ONLY.

    METHODS constructor
      IMPORTING
        iv_message TYPE string OPTIONAL.

ENDCLASS.


CLASS zcx_debit_note_error IMPLEMENTATION.

  METHOD constructor.
    " Call super first (cx_static_check has no mandatory parameters)
    super->constructor( ).
    mv_message = iv_message.
  ENDMETHOD.

ENDCLASS.
