*&---------------------------------------------------------------------*
*& Class    : ZCL_EMAIL_TEMPLATE
*& Purpose  : Loads an HTML e-mail template from the Z-table
*&            ZTMPL_CONTENT and replaces named placeholders such as
*&            {{NOME}}, {{DATA}}, {{TABLE_ROWS}}, etc.
*&
*& Responsibilities (SRP):
*&   - Load raw HTML from database (load_template)
*&   - Substitute placeholders with runtime values (replace_variables)
*&   - Return the final, ready-to-send HTML (build_html)
*&
*& Template storage: ZTMPL_CONTENT
*&   - Avoids the 132-char line limit of SO10 standard texts
*&   - Maintainable via SM30 without recompilation
*&   - See ddic_ztmpl_content.txt for table definition
*&
*& Usage:
*&   DATA(lo_tpl) = NEW zcl_email_template( ).
*&   lo_tpl->load_template( 'ZDEBIT_NOTE_HCB' ).
*&   lo_tpl->replace_variables( VALUE #(
*&     ( name = '{{DATA}}'        value = '29/06/2026' )
*&     ( name = '{{REF}}'         value = 'NDH-2026-001' )
*&     ( name = '{{TABLE_ROWS}}' value = lv_rows_html )
*&     ( name = '{{TOTAL_DEBITO}}' value = '1.500,00 MZN' ) ) ).
*&   DATA(lv_html) = lo_tpl->build_html( ).
*&---------------------------------------------------------------------*
CLASS zcl_email_template DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  " Unit test class accesses inject_raw_html (FOR TESTING method)
  FRIENDS ltcl_email_template_test.

  PUBLIC SECTION.

    " Placeholder pair: name = '{{TAG}}', value = replacement text
    TYPES:
      BEGIN OF ty_placeholder,
        name  TYPE string,
        value TYPE string,
      END OF ty_placeholder,
      tt_placeholders TYPE STANDARD TABLE OF ty_placeholder
                      WITH NON-UNIQUE KEY name.

    " Optional: inject raw HTML at construction time (unit tests only)
    METHODS constructor
      IMPORTING
        iv_raw_html TYPE string OPTIONAL.

    " Load the template from ZTMPL_CONTENT. Raises if not found.
    METHODS load_template
      IMPORTING
        iv_template_id TYPE string
      RAISING
        zcx_debit_note_error.

    " Replace all placeholders. Resets to raw template each call,
    " so calling replace_variables multiple times is safe.
    METHODS replace_variables
      IMPORTING
        it_placeholders TYPE tt_placeholders.

    " Returns the current HTML after placeholder substitution.
    METHODS build_html
      RETURNING
        value(rv_html) TYPE string.

  PRIVATE SECTION.
    DATA mv_raw_template TYPE string.
    DATA mv_html         TYPE string.
    DATA mv_template_id  TYPE string.

    " Reads and concatenates all rows from ZTMPL_CONTENT
    METHODS read_from_db
      IMPORTING
        iv_template_id TYPE string
      RETURNING
        value(rv_html) TYPE string
      RAISING
        zcx_debit_note_error.

    " FOR TESTING — allows unit tests to inject HTML without DB access
    METHODS inject_raw_html FOR TESTING
      IMPORTING
        iv_html TYPE string.

ENDCLASS.


CLASS zcl_email_template IMPLEMENTATION.

  METHOD constructor.
    " When raw HTML is provided (unit tests), skip DB load entirely
    IF iv_raw_html IS NOT INITIAL.
      mv_raw_template = iv_raw_html.
      mv_html         = iv_raw_html.
    ENDIF.
  ENDMETHOD.


  METHOD load_template.
    mv_template_id  = iv_template_id.
    mv_raw_template = read_from_db( iv_template_id ).
    mv_html         = mv_raw_template.
  ENDMETHOD.


  METHOD replace_variables.
    " Always start from the unmodified original so this method is
    " idempotent and safe to call once per employee in a loop.
    mv_html = mv_raw_template.

    LOOP AT it_placeholders INTO DATA(ls_ph).
      " REPLACE ALL covers multiple occurrences of the same tag
      " (e.g. {{DATA}} appears in both the preheader and the header)
      REPLACE ALL OCCURRENCES OF ls_ph-name IN mv_html WITH ls_ph-value.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_html.
    rv_html = mv_html.
  ENDMETHOD.


  METHOD read_from_db.
    " ZTMPL_CONTENT rows ordered by ZSEQ give us the full HTML when
    " concatenated. Each row holds up to 255 chars (no SO10 132-limit).
    SELECT zcontent
      FROM ztmpl_content
      WHERE ztemplate_id = @iv_template_id
      ORDER BY zseq
      INTO TABLE @DATA(lt_lines).

    IF sy-subrc <> 0 OR lt_lines IS INITIAL.
      RAISE EXCEPTION TYPE zcx_debit_note_error
        EXPORTING
          iv_message = |Template HTML não encontrado: '{ iv_template_id }'.|
                    && | Verifique a tabela ZTMPL_CONTENT (SM30).|.
    ENDIF.

    rv_html = REDUCE string(
      INIT acc = ``
      FOR ls_line IN lt_lines
      NEXT acc = acc && ls_line-zcontent ).
  ENDMETHOD.


  METHOD inject_raw_html.
    " Used exclusively by unit tests — bypasses database
    mv_raw_template = iv_html.
    mv_html         = iv_html.
  ENDMETHOD.

ENDCLASS.
