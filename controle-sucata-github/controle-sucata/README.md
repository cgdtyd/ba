# Controle de Sucata

Sistema web em HTML com integração opcional ao Supabase para login e sincronização em nuvem.

## Estrutura

- `index.html` — página principal do sistema.
- `CONFIGURAR_NUVEM.sql` — SQL para configurar as estruturas do Supabase.

## Publicação

O projeto é estático: não precisa de servidor Node.js para abrir a página.

Para GitHub Pages:
1. Crie um repositório.
2. Envie `index.html` e `CONFIGURAR_NUVEM.sql`.
3. Ative o GitHub Pages usando a branch principal e a pasta raiz.

Para Cloudflare Pages:
1. Conecte o repositório do GitHub.
2. Como é um site estático, não use comando de build.
3. Publique a branch principal.

## Supabase

Depois de publicar o site, use no próprio sistema a área de configuração da nuvem para informar a Project URL e a chave publishable/anon do projeto.

Não coloque uma chave `service_role` ou secret no navegador.
