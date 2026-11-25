# The nitro-web compatibility check

**Installs in nitro-web** is a commit status on the head of a pull request into `main`. A success means Bundler could update `nitro_intelligence` to the candidate on the sampled nitro-web default-branch revision. The release PR goes through the same check. [Proposal and historical examples](https://github.com/powerhome/nitro-intelligence.rb/issues/216)

## What contributors see

| Status | What to do |
| --- | --- |
| Pending | Follow the status link to the verifier run. A first-time fork contributor may need a maintainer to approve the initial Actions run. |
| Success | This revision resolved. A push to the PR starts another check. |
| Failure, dependency conflict | Review the gemspec and Ruby requirements. Adjust them or coordinate a prerequisite nitro-web update with its maintainers. |
| Failure, unsupported metadata | Keep the dependency declarations and version literal. For a new gemspec idiom, land support and a fixture in the trusted reader on `main` first. |
| Error | A maintainer can rerun the verifier from the beginning. Repeated errors can indicate an App, toolchain, registry or lockfile-format change. |

An old status describes the snapshot at the time it ran. After a nitro-web dependency change, rerun the request workflow on the current open PR to sample the new snapshot. A PR that disables or skips its request workflow needs a run on its head before it can satisfy the rule.

## How the check works

The `pull_request` workflow runs the public regression tests whenever a PR into `main` opens, reopens, or receives a new commit. Its completion triggers the compatibility check.

The `workflow_run` verifier checks out its own protected-main revision, looks up the open PR in the base repository, and matches the workflow run's head repository ID, branch and commit. This lookup also handles fork runs with an empty `pull_requests` array. The verifier fetches the base repository's PR head ref anonymously and compares its SHA before reading the two regular Git blobs for the gemspec and version. It accepts the supported literal declarations and rejects other Ruby programs. It runs no candidate Ruby and consumes no PR artifacts.

The reader App fetches the top-level `Gemfile.lock` and `.ruby-version` at one default-branch SHA. A disposable container uses that Ruby and the lockfile's `BUNDLED WITH` version. It reconstructs the Gemfile roots and locked graph, substitutes generated gemspecs for path and Git gems, moves their pins and the root pin to the candidate version, and runs `bundle lock --update nitro_intelligence`. It checks that Bundler selected the candidate's dependencies and preserved unrelated locked versions.

The verifier fetches public RubyGems compact-index records using only the public candidate dependency names and their published dependencies. The private resolver has networking disabled. A loopback registry supplies those public records and the original locked records for the rest of the graph. Private files stay on the hosted runner. The reporting App receives a fixed verdict. Logs, summaries, caches and artifacts carry no lockfile, generated gemspecs, Bundler explanation or lockfile diff. Maintainers investigating a conflict can reproduce it in their private environment. [RubyGems compact index](https://guides.rubygems.org/rubygems-org-compact-index-api/)

## One-time setup

1. An organization App administrator creates a private reader GitHub App. Disable webhooks. Grant repository **Contents: read-only** and install it on **only `powerhome/nitro-web`** using *Only select repositories*. GitHub also grants its mandatory metadata access. The key can read that entire repository, so limit App managers and keep it separate from the release App.
2. Create a separate private reporter GitHub App with webhooks disabled and only **Commit statuses: read and write** plus mandatory metadata access. Install it on **only `powerhome/nitro-intelligence.rb`**. Record its numeric App ID for the ruleset. The reporter identity binds the required result to the trusted workflow.
3. In the public gem repository, create the **`nitro-web-compat`** Actions environment. Under *Deployment branches and tags*, choose *Selected branches and tags*. Add exactly one rule of type **Branch** with the literal name **`main`**. Keep the tag list empty. Confirm the restriction before adding keys. Keep the repo's protected-main review rules in force. The environment can run automatically without a required reviewer.
4. Generate a private key for each App and put it directly into the corresponding **environment secret** below. Use the environment variables for the client IDs. Keep copies out of repository and organization Actions secrets, files, logs and PRs. Rotate keys through the same environment.

| App | Environment variable | Environment secret |
| --- | --- | --- |
| `nitro-web-compat-reader` | `NITRO_WEB_COMPAT_READER_CLIENT_ID` | `NITRO_WEB_COMPAT_READER_PRIVATE_KEY` |
| `nitro-web-compat-reporter` | `NITRO_WEB_COMPAT_REPORTER_CLIENT_ID` | `NITRO_WEB_COMPAT_REPORTER_PRIVATE_KEY` |

GitHub matches environment deployment branches against the job ref. Restricting the environment to the literal branch lets the verifier execute on `main` while a PR or a branch push cannot deploy to it. The reporter App installation needs no access to nitro-web. [Environment deployment rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)

## Bootstrap before making the check required

1. Review and merge the verifier onto protected `main` under the existing rules. Leave **Installs in nitro-web** optional through the following acceptance runs. GitHub loads a `workflow_run` workflow from the default branch. [Workflow run events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
2. Open a same-repository draft PR with a compatible change. Verify that the reporter posts pending and then success on its exact head SHA. Push a second commit with a dependency requirement verified incompatible against the current snapshot. Verify that the new SHA receives failure and the old SHA retains its own result. Restore the compatible requirement and check the next SHA. #209, #210 and #215 illustrate past changes to `activesupport`, `langfuse-rb` and `mini_magick`. Recheck current constraints before choosing one.
3. On that disposable branch, add an ordinary `pull_request` job with `environment: nitro-web-compat` and a single harmless `run: echo reached` step. Verify that GitHub rejects the deployment before assigning a runner and the step never executes. Repeat on a branch push if testing both event types. This exercise requires no secret reference. Confirm the trusted check can still report for the PR.
4. Open or update a draft PR from a fork, approving the unprivileged Actions run if the repository requires it. Verify the status was written in the base repo for the fork's exact head. Inspect each SHA with the command below. Compare the status creator with the reporter App's bot login and follow the target URL. Review the public logs and artifact list for both a pass and a failure.
5. After a successful report, edit the existing `main` ruleset. Add **Installs in nitro-web**, select the **reporter GitHub App** as the expected source and require branches to be up to date before merging. Preserve the existing checks. For an API-managed ruleset, the status context's `integration_id` is the reporter's numeric App ID. Verify the effective rule using the second command. A same-named status from a branch writer or GitHub Actions must leave the merge blocked. [Required status check sources](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-status-checks-to-pass-before-merging)
6. Rerun the request workflow for existing open PRs into `main` that already have a run on their current head. Reopen or update the others. Record the acceptance-run links, public head SHAs and verdicts in the rollout record.

```sh
gh api "repos/powerhome/nitro-intelligence.rb/commits/$PR_HEAD_SHA/status" \
  --jq '.statuses[] | select(.context == "Installs in nitro-web") | [.state, .creator.login, .target_url]'
gh api repos/powerhome/nitro-intelligence.rb/rules/branches/main \
  --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | select(.context == "Installs in nitro-web")'
```
