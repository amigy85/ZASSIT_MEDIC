*"* use this source file for your ABAP unit test classes
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
