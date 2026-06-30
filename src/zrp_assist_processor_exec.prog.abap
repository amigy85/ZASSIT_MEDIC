*&---------------------------------------------------------------------*
*& Report  : ZRP_ASSIST_PROCESSOR_EXEC  (REFACTORED)
*& Purpose : Entry point for the HCB Medical Assistance debit-note
*&           loading and notification process.
*&
*& Changes from original:
*&   - Individual CX exceptions still caught at top level (fallback)
*&   - ZCX_DEBIT_NOTE_ERROR added as a specific catch
*&   - Final MESSAGE type 'S' is informational; the BAL log (SLG1)
*&     shown by ENVIAR_EMAILS contains the full processing detail
*&---------------------------------------------------------------------*
REPORT zrp_assist_processor_exec.


" ── Selection screen ─────────────────────────────────────────────────
PARAMETERS: p_file TYPE rlgrap-filename OBLIGATORY.


AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  DATA: lt_files TYPE filetable,
        lv_rc    TYPE i.

  cl_gui_frontend_services=>file_open_dialog(
    EXPORTING
      window_title      = 'Selecionar arquivo de dados'
      default_extension = 'txt'
      file_filter       = 'Arquivos TXT (*.txt)|*.txt|CSV (*.csv)|*.csv'
    CHANGING
      file_table        = lt_files
      rc                = lv_rc
    EXCEPTIONS
      OTHERS            = 1 ).

  IF sy-subrc = 0 AND lv_rc > 0.
    READ TABLE lt_files INTO p_file INDEX 1.
  ENDIF.


" ── Main processing ──────────────────────────────────────────────────
START-OF-SELECTION.

  TRY.
      DATA(lo_proc) = NEW zcl_medical_assist_process( iv_file = p_file ).

      lo_proc->upload_dados( ).         " Load CSV from frontend
      lo_proc->validar_dados( ).        " Mark invalid records (no aborts)
      lo_proc->carregar_lancamentos( ). " Post FI documents via BAPI
      lo_proc->enviar_emails( ).        " Send HTML e-mails + show BAL log

      " Informational status bar message — full detail is in SLG1 log
      MESSAGE 'Processamento concluído. Consulte o log de aplicação (SLG1 / ZDEBIT_NOTE).'
        TYPE 'S'.

    CATCH zcx_debit_note_error INTO DATA(lx_domain).
      MESSAGE lx_domain->mv_message TYPE 'E'.

    CATCH cx_sy_file_access_error INTO DATA(lx_file).
      MESSAGE lx_file->get_text( ) TYPE 'E'.

    CATCH cx_bcs INTO DATA(lx_bcs).
      " CX_BCS at this level means ENVIAR_EMAILS re-raised unexpectedly
      MESSAGE lx_bcs->get_text( ) TYPE 'E'.

    CATCH cx_root INTO DATA(lx_root).
      MESSAGE lx_root->get_text( ) TYPE 'E'.
  ENDTRY.
