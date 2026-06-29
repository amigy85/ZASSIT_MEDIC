================================================================================
GUIA DE IMPLEMENTAÇÃO — HCB Nota de Débito Assistência Médica
Sistema: SAP on-premise · ABAP 7.40
================================================================================

ORDEM DE CRIAÇÃO DOS OBJETOS
────────────────────────────

1. DDIC — Tabela ZTMPL_CONTENT         (SE11)
2. SM30 — Maintenance View             (SE54 / SE56)
3. Classe ZCX_DEBIT_NOTE_ERROR         (SE24 / ADT)
4. Classe ZCL_BAL_LOGGER               (SE24 / ADT)
5. Classe ZCL_EMAIL_TEMPLATE           (SE24 / ADT)
6. Classe ZCL_EMAIL_SERVICE            (SE24 / ADT)
7. Classe ZCL_DEBIT_NOTE_NOTIFICATION  (SE24 / ADT)
8. Classe ZCL_MEDICAL_ASSIST_PROCESS   (SE24 / ADT)
9. Report ZRP_ASSIST_PROCESSOR_EXEC    (SE38 / ADT)
10. Carregar template no ZTMPL_CONTENT  (ZLOAD_EMAIL_TEMPLATE)

================================================================================
PASSO 1 — CRIAR A TABELA ZTMPL_CONTENT (SE11)
================================================================================

1. SE11 → Tabelas de base de dados → ZTMPL_CONTENT → Criar
2. Descrição curta: "HTML Template Content Lines"
3. Campos (separador de campos na aba "Campos"):

   Nome Campo     Chave  Tipo elem.    Compr  Tipo dados  Descrição
   MANDT          X      MANDT         3      CLNT        Mandante
   ZTEMPLATE_ID   X      (tipo manual) 30     CHAR        Template ID
   ZSEQ           X      (tipo manual) 6      NUMC        Sequência
   ZCONTENT             (tipo manual) 255     CHAR        Conteúdo HTML

4. Configurações técnicas:
   - Classe de dados: USER
   - Categoria de tamanho: 0
   - Buffering: Sem buffering

5. Ativar a tabela

================================================================================
PASSO 2 — CRIAR VISTA DE MANUTENÇÃO SM30
================================================================================

1. SE54 → Gerar objetos de manutenção para ZTMPL_CONTENT
   - Permitir: Leitura, Escrita, Novas entradas, Eliminação
   - Gerar vista de manutenção simplificada

OU manualmente via SE56:
   - Nome vista: ZTMPL_CONTENT_V
   - Tabela base: ZTMPL_CONTENT
   - Tipo de vista: Manutenção

================================================================================
PASSO 3 — CRIAR OBJETOS BAL (SLG0)
================================================================================

1. SLG0 → Novo → Criar objeto de log:
   - Objeto: ZDEBIT_NOTE
   - Texto: "HCB Nota de Débito Assistência Médica"

2. Criar sub-objecto:
   - Sub-objeto: FI_POST  → "Lançamentos FI"
   - Sub-objeto: EMAIL_NOTIF → "Notificações E-mail"

================================================================================
PASSO 4 — CRIAR CLASSES ABAP (SE24 / ADT)
================================================================================

Criar as classes na seguinte ordem (dependências):

A. ZCX_DEBIT_NOTE_ERROR
   - Tipo: Classe de exceção
   - Superclasse: CX_STATIC_CHECK
   - Atributo: MV_MESSAGE (string, READ-ONLY, público)
   - Colar código de: zcx_debit_note_error.abap

B. ZCL_BAL_LOGGER
   - Tipo: Classe global
   - Colar código de: zcl_bal_logger.abap

C. ZCL_EMAIL_TEMPLATE
   - Tipo: Classe global
   - Amigo (Friends): LTCL_EMAIL_TEMPLATE_TEST
   - Colar código de: zcl_email_template.abap
   - Nota: A classe de teste local (ltcl_email_template_test) fica no
     include de testes (CCAU) em ADT, ou no final do código em SE24

D. ZCL_EMAIL_SERVICE
   - Tipo: Classe global
   - Colar código de: zcl_email_service.abap

E. ZCL_DEBIT_NOTE_NOTIFICATION
   - Tipo: Classe global
   - Amigo (Friends): LTCL_NOTIFICATION_TEST
   - Colar código de: zcl_debit_note_notification.abap

F. ZCL_MEDICAL_ASSIST_PROCESS
   - Tipo: Classe global
   - Colar código de: zcl_medical_assist_process.abap

G. ZRP_ASSIST_PROCESSOR_EXEC
   - Tipo: Programa ABAP (Report)
   - Colar código de: zrp_assist_processor_exec.abap

================================================================================
PASSO 5 — CARREGAR O TEMPLATE HTML NO ZTMPL_CONTENT
================================================================================

OPÇÃO A — Via SM30 (manual, para poucos registros):
   1. SM30 → ZTMPL_CONTENT_V → Novas entradas
   2. Copiar o conteúdo de: template-nota-debito-hcb-ztmpl.html
   3. Colar linha a linha com ZTEMPLATE_ID = 'ZDEBIT_NOTE_HCB'
      e ZSEQ incrementando: 000001, 000002, ...

OPÇÃO B — Via programa carregador (RECOMENDADO):
   1. Criar programa ZLOAD_EMAIL_TEMPLATE (código no ddic_ztmpl_content.txt)
   2. Executar em modo foreground:
      - p_file: caminho para template-nota-debito-hcb-ztmpl.html
      - p_id:   ZDEBIT_NOTE_HCB
      - p_del:  X (apaga registros anteriores antes de inserir)

================================================================================
PASSO 6 — VERIFICAR PARAMETRIZAÇÃO SAPconnect (SCOT)
================================================================================

1. SCOT → Nós → verificar que o nó de e-mail SMTP está activo
2. Confirmar que o endereço remetente padrão está configurado:
   SCOT → Settings → Default domain → e.g. hcb.co.mz
3. Job de envio RSCONN01 deve estar agendado periodicamente (a cada 5-15 min)

================================================================================
PASSO 7 — VERIFICAR SUBTIPO PA0105
================================================================================

Confirmar o subtipo de e-mail em PA30:
   1. PA30 → Infotype 0105 → verificar qual subtipo contém o e-mail corporativo
   2. Padrão esperado: subtipo '0010' (e-mail corporativo)
   3. Se diferente, alterar a constante C_PA0105_SUBTYPE em
      ZCL_DEBIT_NOTE_NOTIFICATION

================================================================================
ESTRUTURA DO ARQUIVO CSV DE ENTRADA
================================================================================

O arquivo CSV deve ser separado por TAB (não vírgula) com as seguintes
colunas na mesma ordem que os campos de TY_DADO em ZCL_MEDICAL_ASSIST_PROCESS:

Col  Campo          Tipo    Exemplo         Descrição
1    PERNR          Char8   00001234        Número de pessoal
2    NOME           Char40  João Silva      Nome completo
3    NATUREZA       String  Consulta Médica Natureza do custo
4    BENEFICIARIO   String  Titular         Nome do beneficiário
5    CONTA          Char10  0000622000      Conta G/L despesa
6    CENTRO_CUSTO   Char10  HCB001          Centro de custo
7    BUKRS          Char4   HCB             Empresa
8    DATA           Char8   29062026        Data lançamento DDMMYYYY
9    DOC_DAT        Char8   01062026        Data documento DDMMYYYY
10   VALOR          Dec13.2 500.00          Valor débito colaborador
11   VAL_HCB        Dec13.2 1500.00         Valor porção HCB
12   DEBITO         Dec13.2 500.00          Valor débito e-mail
13   DOCUMENTO      Char10  (em branco)     Preenchido pelo programa
14   REFERENCIA     Char20  NDH-2026-06     Referência do documento
15   WAERS          Char5   MZN             Moeda (padrão: MZN)

================================================================================
DIAGRAMA DA ARQUITECTURA
================================================================================

  ZRP_ASSIST_PROCESSOR_EXEC
          │
          ▼
  ZCL_MEDICAL_ASSIST_PROCESS  ──────────────────────────────────┐
  ├── upload_dados()                                            │
  │    └── CL_GUI_FRONTEND_SERVICES::GUI_UPLOAD                │
  ├── validar_dados()                                          │
  │    └── Marca is_valid = false (sem MESSAGE 'E')            │
  ├── carregar_lancamentos()                                   │
  │    └── BAPI_ACC_DOCUMENT_POST (por documento)              │
  │        BAPI_TRANSACTION_COMMIT (por documento)             │
  └── enviar_emails()                                          │
       └── ZCL_DEBIT_NOTE_NOTIFICATION                         │
            ├── build_employee_map()                           │
            ├── load_emails_bulk()                             │
            │    └── SELECT PA0105 (todos os PERNRs de 1x)    │
            └── LOOP por colaborador (TRY/CATCH por emp.)     │
                 ├── build_employee_html()                    │
                 │    └── ZCL_EMAIL_TEMPLATE                  │
                 │         ├── load_template() → ZTMPL_CONTENT│
                 │         ├── replace_variables()             │
                 │         └── build_html()                   │
                 └── send_employee_email()                    │
                      └── ZCL_EMAIL_SERVICE                   │
                           ├── create_document() → CL_DOCUMENT_BCS
                           ├── add_recipient()  → CL_CAM_ADDRESS_BCS
                           └── send()           → CL_BCS / SCOT
                                                               │
  ZCL_BAL_LOGGER ◄──────────────────────────────────────────────┘
  (Todos os componentes logam para o mesmo objeto BAL ZDEBIT_NOTE)
  Visível em SLG1 após execução.

================================================================================
MELHORIAS FUTURAS RECOMENDADAS
================================================================================

1. OPEN DATASET em vez de GUI_UPLOAD
   - GUI_UPLOAD não funciona em background jobs (batch)
   - Para automação: substituir por OPEN DATASET + READ DATASET
   - Permitiria agendar via SM36 sem intervenção de utilizador

2. Anexo de logótipo como CID (Content-ID)
   - O HTML referencia src="cid:logo_hcb" mas o logo não é anexado
   - Usar CL_DOCUMENT_BCS=>ADD_ATTACHMENT para anexar o logo como inline
   - Armazenar o logo em MIME Repository (SMW0)

3. Workflow SAP (SWDD)
   - Substituir e-mail directo por Work Item no Business Workplace
   - Permite tracking de leitura e aprovação

4. API REST / SAP Integration Suite
   - Para integração com sistemas externos (RH, portais self-service)
   - ZCL_DEBIT_NOTE_NOTIFICATION pode ser exposto como REST endpoint

5. ABAP Unit Tests — cobertura completa
   - Actualmente: ZCL_EMAIL_TEMPLATE (6 testes) + ZCL_DEBIT_NOTE_NOTIFICATION (5 testes)
   - Adicionar: mock de CL_BCS para testar ZCL_EMAIL_SERVICE sem servidor de e-mail
   - Usar CL_ABAP_TESTDOUBLE_FRAMEWORK (disponível 7.40+)

6. Controlo de autorizações
   - Adicionar AUTHORITY-CHECK OBJECT 'P_ORGIN' antes de aceder a PA0105
   - Adicionar verificação de autorização FI antes de BAPI_ACC_DOCUMENT_POST

7. Relatório de execução ALV
   - Em vez de apenas o BAL log, gerar um ALV com: PERNR, nome, status, e-mail, doc FI
   - Permite ao utilizador ver o resultado de cada registo numa grelha

================================================================================
