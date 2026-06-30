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
  CREATE PUBLIC.

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


*&---------------------------------------------------------------------*
*& ABAP Unit Tests — compiled into the CCAU test include (FOR TESTING)
*& Run via ADT: right-click class → Run As → ABAP Unit Test
*&---------------------------------------------------------------------*
CLASS ltcl_email_template_test DEFINITION FINAL FOR TESTING
  RISK LEVEL HARMLESS
  DURATION SHORT.

  PRIVATE SECTION.
    DATA mo_cut TYPE REF TO zcl_email_template.

    METHODS setup.

    " Happy path: single placeholder replaced correctly
    METHODS test_single_placeholder FOR TESTING.

    " Multiple different placeholders all replaced in one call
    METHODS test_multiple_placeholders FOR TESTING.

    " Placeholder appears twice in template — both occurrences replaced
    METHODS test_repeated_placeholder FOR TESTING.

    " replace_variables resets to raw; second call must override first
    METHODS test_replace_is_idempotent FOR TESTING.

    " build_html after replace_variables returns the substituted HTML
    METHODS test_build_html_returns_final FOR TESTING.

    " Loading a non-existent template ID raises zcx_debit_note_error
    METHODS test_load_nonexistent_raises FOR TESTING.

ENDCLASS.


CLASS ltcl_email_template_test IMPLEMENTATION.

  METHOD setup.
    " Inject raw HTML directly — no database access needed
    mo_cut = NEW zcl_email_template( ).
    mo_cut->inject_raw_html(
      '<html>{{DATA}} {{NOME}} {{DATA}} {{VALOR}}</html>' ).
  ENDMETHOD.


  METHOD test_single_placeholder.
    DATA(lt_ph) = VALUE zcl_email_template=>tt_placeholders(
      ( name = '{{NOME}}' value = 'João Silva' ) ).

    mo_cut->replace_variables( lt_ph ).
    DATA(lv_result) = mo_cut->build_html( ).

    cl_abap_unit_assert=>assert_char_cp(
      act  = lv_result
      exp  = '*João Silva*'
      msg  = 'Nome não foi substituído' ).
  ENDMETHOD.


  METHOD test_multiple_placeholders.
    DATA(lt_ph) = VALUE zcl_email_template=>tt_placeholders(
      ( name = '{{NOME}}'  value = 'Maria Santos' )
      ( name = '{{VALOR}}' value = '2.000,00'     )
      ( name = '{{DATA}}'  value = '29/06/2026'   ) ).

    mo_cut->replace_variables( lt_ph ).
    DATA(lv_result) = mo_cut->build_html( ).

    cl_abap_unit_assert=>assert_char_cp(
      act = lv_result exp = '*Maria Santos*'
      msg = 'Nome não substituído' ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv_result exp = '*2.000,00*'
      msg = 'Valor não substituído' ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv_result exp = '*29/06/2026*'
      msg = 'Data não substituída' ).
  ENDMETHOD.


  METHOD test_repeated_placeholder.
    " {{DATA}} appears twice in the injected template
    DATA(lt_ph) = VALUE zcl_email_template=>tt_placeholders(
      ( name = '{{DATA}}' value = '01/07/2026' ) ).

    mo_cut->replace_variables( lt_ph ).
    DATA(lv_result) = mo_cut->build_html( ).

    " Count occurrences of the substituted value
    DATA lv_count TYPE i.
    FIND ALL OCCURRENCES OF '01/07/2026' IN lv_result MATCH COUNT lv_count.

    cl_abap_unit_assert=>assert_equals(
      exp = 2  act = lv_count
      msg = 'Ambas as ocorrências de {{DATA}} devem ser substituídas' ).
  ENDMETHOD.


  METHOD test_replace_is_idempotent.
    " First call
    mo_cut->replace_variables( VALUE #(
      ( name = '{{NOME}}' value = 'Primeiro' ) ) ).
    " Second call with different value — must override, not accumulate
    mo_cut->replace_variables( VALUE #(
      ( name = '{{NOME}}' value = 'Segundo' ) ) ).

    DATA(lv_result) = mo_cut->build_html( ).

    cl_abap_unit_assert=>assert_char_cp(
      act = lv_result exp = '*Segundo*'
      msg = 'Segunda chamada deve usar o template original' ).

    " 'Primeiro' must not appear (raw template reset each call)
    cl_abap_unit_assert=>assert_char_np(
      act = lv_result exp = '*Primeiro*'
      msg = 'Valor da primeira chamada não deve persistir' ).
  ENDMETHOD.


  METHOD test_build_html_returns_final.
    mo_cut->replace_variables( VALUE #(
      ( name = '{{NOME}}'  value = 'Test User' )
      ( name = '{{DATA}}'  value = '29/06/2026' )
      ( name = '{{VALOR}}' value = '500,00' ) ) ).

    DATA(lv_html) = mo_cut->build_html( ).

    " After full substitution, no placeholder tags should remain
    cl_abap_unit_assert=>assert_char_np(
      act = lv_html  exp = '*{{*'
      msg = 'Não devem restar placeholders não substituídos' ).
  ENDMETHOD.


  METHOD test_load_nonexistent_raises.
    DATA(lo_tpl)  = NEW zcl_email_template( ).
    DATA lx_error TYPE REF TO zcx_debit_note_error.

    TRY.
        lo_tpl->load_template( '##NAO_EXISTE##' ).
        cl_abap_unit_assert=>fail(
          'Deve ter levantado zcx_debit_note_error para template inexistente' ).
      CATCH zcx_debit_note_error INTO lx_error.
        cl_abap_unit_assert=>assert_not_initial(
          act = lx_error->mv_message
          msg = 'A exceção deve conter uma mensagem descritiva' ).
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
