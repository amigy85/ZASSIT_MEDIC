*"* use this source file for your ABAP unit test classes
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
