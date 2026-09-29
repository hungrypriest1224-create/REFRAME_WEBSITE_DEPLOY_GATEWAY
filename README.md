# RE:FRAME Website Deploy Gateway

This public repository contains only the workflow and code needed to read the private RE:FRAME source from Google Drive, run its checks, and deploy it to Cloudflare Workers. The website source, page copy, KFB preview, and assets remain in the private Drive `30_SOURCE` folder.

## Deploy flow

1. Change the private Drive source.
2. Update `.deploy/production-request.json` on `main`, or use **Actions → Deploy RE:FRAME from Drive → Run workflow**.
3. GitHub Actions obtains a read-only Google Drive token, copies one stable source snapshot into the runner's temporary directory, checks the snapshot did not change during download, then runs the source build and authentication checks.
4. Wrangler deploys the verified build to the existing `reframe-web` Worker. The workflow checks the live Worker URL for public pages, robots policy, and the unauthenticated KFB page and assets.
5. The runner removes the temporary Drive snapshot. It does not upload source or browser artifacts.

The request file contains no website source. A Drive edit alone does not trigger a build; the request commit or workflow dispatch tells Actions when to fetch the latest Drive state.

## Required GitHub Actions secrets

- `GDRIVE_SERVICE_ACCOUNT_JSON`: a dedicated Google service account JSON key with Viewer access only to the RE:FRAME `30_SOURCE` folder and read-only Drive API scope.
- `CLOUDFLARE_API_TOKEN`: a dedicated Cloudflare API token limited to the RE:FRAME Worker deployment and the minimum required account permissions.
- `CLOUDFLARE_ACCOUNT_ID`: the user's Cloudflare account ID. It is not secret, but Actions reads it from Secrets with the token.

Set `REFRAME_AUTH_PASSWORD_MAC` and `REFRAME_AUTH_SESSION_SECRET` once as Cloudflare Worker secrets before the first deploy. ChatGPT Sites masks their values, so they cannot be copied through the connector; use the existing KFB password to generate a new session secret and matching password MAC with the private setup procedure. Do not put either value in this repository or in a workflow artifact.

## Free-plan boundary

This Gateway targets the public standard GitHub-hosted runner and Cloudflare Workers Free plan. Do not add paid products, enable billing, or change the Worker to a paid plan without explicit user approval. Public static assets should be served asset-first; only the password-gated KFB and login routes should consume Worker requests.

## Recovery

When Actions or GitHub is unavailable, use the latest Drive `30_SOURCE` snapshot on a PC and run `scripts/deploy-cloudflare.ps1`. That script uses the same build, auth tests, Wrangler config, Worker name, and live checks.

