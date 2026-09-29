# RE:FRAME Website Deploy Gateway

This public repository contains only the workflow and code needed to read the private RE:FRAME source from Google Drive, run its checks, and deploy it to Cloudflare Workers. The website source, page copy, KFB preview, and assets remain in the private Drive `30_SOURCE` folder.

## Deploy flow

1. Change the private Drive source.
2. Update `.deploy/production-request.json` on `main`, or use **Actions → Deploy RE:FRAME from Drive → Run workflow**.
3. GitHub Actions obtains a read-only Google Drive token, copies one stable source snapshot into the runner's temporary directory, checks the snapshot did not change during download, then runs the source build and authentication checks.
4. Wrangler deploys the verified build to the existing `reframe-web` Worker. The workflow checks the live Worker URL for public pages, robots policy, and the unauthenticated KFB page and assets.
5. The runner removes the temporary Drive snapshot. It does not upload source or browser artifacts.

The request file contains no website source. A Drive edit alone does not trigger a build; the request commit or workflow dispatch tells Actions when to fetch the latest Drive state.

## One-time setup

1. In the RE:FRAME Cloudflare account, create a Worker named `reframe-web` and enable its `workers.dev` address. Keep the custom domain disconnected until the preview, KFB authentication, and rollback checks pass.
2. Before the first Gateway deploy, run `scripts/initialize-cloudflare-secrets.ps1` from the Drive source on a PC. It asks for the existing KFB password without displaying or saving it, creates a new session secret and matching password MAC, and sends both directly to the `reframe-web` Worker as Cloudflare secrets. Never put the password in GitHub Actions or chat.
3. Create a Cloudflare API token with the `Editor` role scoped to the individual `reframe-web` Worker. The Worker must already exist before Cloudflare can scope a token to that resource. The Gateway only updates this Worker and does not need DNS or zone permissions for `workers.dev` deploys.
4. Create a dedicated Google service account in a project with no billing account, enable the Drive API, and grant that identity Viewer access only to the RE:FRAME `30_SOURCE` folder. Store its JSON key in the Gateway's `GDRIVE_SERVICE_ACCOUNT_JSON` Actions secret.
5. Store the Worker-scoped token and the Cloudflare account ID in the Gateway's Actions secrets, then run the workflow. Do not give GitHub a product-level Workers Admin token to create resources.

The initial Cloudflare Worker and secrets are one-time bootstrap steps. After that, normal deployments run from a phone or browser through GitHub Actions; a PC is only needed for the recovery script or to rotate the KFB secrets.

## Required GitHub Actions secrets

- `GDRIVE_SERVICE_ACCOUNT_JSON`: a dedicated Google service account JSON key with Viewer access only to the RE:FRAME `30_SOURCE` folder and read-only Drive API scope.
- `CLOUDFLARE_API_TOKEN`: a Cloudflare `Editor` token scoped only to the existing `reframe-web` Worker. It does not need DNS or zone permissions for the `workers.dev` preview deploy.
- `CLOUDFLARE_ACCOUNT_ID`: the user's Cloudflare account ID. It is not secret, but Actions reads it from Secrets with the token.

Set `REFRAME_AUTH_PASSWORD_MAC` and `REFRAME_AUTH_SESSION_SECRET` once as Cloudflare Worker secrets before the first deploy. ChatGPT Sites masks their values, so they cannot be copied through the connector; use the existing KFB password to generate a new session secret and matching password MAC with the private setup procedure. Do not put either value in this repository or in a workflow artifact.

## Free-plan boundary

This Gateway targets the public standard GitHub-hosted runner and Cloudflare Workers Free plan. Public standard GitHub-hosted runners are free for public repositories. On the Cloudflare Free plan, static asset requests are free and unlimited; only the password-gated KFB and login routes invoke the Worker. Those routes share the account's 100,000 Worker requests/day limit and can return 429 after that limit is reached. Do not add paid products, enable billing, or change the Worker to a paid plan without explicit user approval.

## Recovery

When Actions or GitHub is unavailable, use the latest Drive `30_SOURCE` snapshot on a PC and run `scripts/deploy-cloudflare.ps1`. That script uses the same build, auth tests, Wrangler config, Worker name, and live checks.

