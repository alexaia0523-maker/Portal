# Sala de Questões – Fábrica Maluca do Relê (alunos + professor)

Arquivos
- `index.html`     → site do ALUNO (cria usuário, responde, nota salva automaticamente)
- `professor.html` → painel do PROFESSOR (notas da turma, questões mais erradas, liberar/bloquear fases, Excel/PDF)
- `config.js`      → onde você cola os dados do seu Supabase
- `supabase.sql`   → cria o banco (cole no SQL Editor do Supabase)

## Passo a passo (uns 10 minutos)

1. **Banco:** no Supabase abra seu projeto → **SQL Editor** → New query → cole todo o `supabase.sql` → **Run**.
2. **Seu usuário de professor:** **Authentication → Users → Add user → Create new user**
   (e-mail + senha, marque *Auto Confirm User*). Depois, no SQL Editor, rode (com o SEU e-mail):
   `insert into public.teachers(user_id) select id from auth.users where email = 'seu@email.com';`
3. **Bloqueie cadastros de e-mail:** **Authentication → Sign In / Providers → Email** e desative *Allow new users to sign up*
   (os alunos NÃO usam essa área; eles têm o próprio cadastro nome + turma + PIN).
4. **Chaves:** **Project Settings → API**. Copie *Project URL* e a chave *anon public* para o `config.js`.
   (Nunca use a chave `service_role` aqui.)
5. **Publicar:** coloque os 4 arquivos em um repositório do GitHub e ative **Settings → Pages**
   (branch `main`, pasta `/root`). Links finais:
   - alunos: `https://SEU-USUARIO.github.io/NOME-DO-REPO/`
   - professor: `https://SEU-USUARIO.github.io/NOME-DO-REPO/professor.html`
   (Também funciona em Netlify, ou abrindo os arquivos direto no computador.)

## Como funciona
- Aluno: **Criar meu usuário** (nome + turma + PIN de 4 números) uma vez; depois **Entrar**. Funciona em qualquer aparelho.
- O PIN fica criptografado. Após 5 PINs errados o usuário trava por 5 minutos.
- A nota é salva ao terminar cada fase (guarda a melhor nota e conta as tentativas).
- Professor: entra com e-mail/senha. Clique no nome do aluno para **redefinir o PIN** ou **excluir**.
- Aba **Liberar fases**: bloqueia/libera fases para todos (fase bloqueada não aceita notas).
- **Exportar Excel** gera um CSV (abre no Excel) · **Imprimir / PDF** usa a impressão do navegador.

## Limites honestos
- O aluno corrige no próprio navegador; um aluno muito técnico poderia forjar a nota pela API.
  Para uso em sala de aula isso costuma bastar; para prova valendo nota, acompanhe presencialmente.
- Plano gratuito do Supabase pausa o projeto após 1 semana sem uso: antes de uma aula, abra o painel do Supabase e clique em *Restore* se estiver pausado.
