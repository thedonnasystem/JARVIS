# Client 2: life-insurance professional (FF Marketing onboarding)

Status: process and data model only. THE RECRUITING MODEL IS NOT FINALISED AND IS NOT ASSUMED ANYWHERE. The template item `recruiting_model` is required and starts unset; the workspace cannot activate until the owner records the decision. Budget, geography, CRM and dates are likewise unset. Compliance notes are items to CONFIRM, not legal advice.

## What is and is not decided
| Decided | Not decided (owner/client must provide) |
|---|---|
| Same OS, isolated workspace (vertical `insurance`) | Recruiting model: who recruits, who is recruited, who employs/contracts, what is offered |
| Draft-only campaigns, owner-gated activation | Whether the work is client acquisition, recruiting, or both |
| Lead fields restricted to the allow-list | Budget, geography, CRM, timeline |
Do not write recruiting ad copy, funnel stages or earnings claims until `recruiting_model` is recorded.

## Step-by-step
1. Owner creates workspace (vertical `insurance`, `draft`); run `ffm_instantiate_onboarding` (13 items; `recruiting_model` is required and starts unset).
2. Owner records `recruiting_model` once decided, and sets the monthly budget (owner-only).
3. Client provides licensing/sponsoring-agency status, ad sign-off route (agency or MGA), consent wording, geography, CRM, booking link, compliance contact, ad-account access, lead-field list.
4. Draft campaigns only after step 2. The funnel stages in `ws_leads` (new, contacted, booked, handed_off, lost) fit client-acquisition leads; if the model is recruiting, confirm whether these stages and the reports still make sense before reuse.
5. Owner approves activation (owner-only); later changes make it stale. Going live is a separate owner gate.

## What the AI may and may not touch
Same split as Client 1: marketing drafts and counts only. It must not handle policy applications, health information, banking, ID or other sensitive personal or financial data (life insurance leads often volunteer health details; the note field is NOT routed, and the guard refuses banking/ID/income terms and health information about a person; treat any health detail in a lead note as a human-only matter).

## Insurance product wording versus personal health information (20261122)
Ordinary product wording ("health insurance", "disability insurance", "critical illness insurance", "assurance santé", "assurance invalidité", "Medicine Hat") used to be refused by the health detector. It is now permitted ONLY as an exact, owner-approved term (table `ws_approved_terms`, shipped EMPTY; with no approved term the old fail-closed behaviour applies unchanged) and ONLY in non-person tables (campaign names, ad sets, creatives, approvals, onboarding values, ledger notes). Full model and limits: `DATA_CLASSIFICATION_AND_BACKUP_POLICY.md` section 5a.
- Allowed once approved: "Protect your family with health insurance", "Critical illness insurance from $25/month", "Assurance invalidité pour les travailleurs autonomes".
- Always refused: personal medical information, a person's disability or claim, application details, SIN / ID / banking / credit / income, policy or claim numbers, dates of birth, and any phone, email, postal code, street address or 4+ digit number next to a health product phrase. Anything with first-person or narrative context ("my", "I", "j'ai", "ma mère", "diagnosed", "claim for my surgery", "passed away") is refused even if an approved term is present. Ambiguous text is refused.
- Lead records (`ws_leads`) and workspace names stay strict: a lead note such as "interested in health insurance" is still refused. Record the interest in the client's own CRM.
- Writing: draft copy WITHOUT first-person words, numbers other than prices, years and age ranges, and without health words that are not themselves part of an approved term ("no medical exam", "healthy", "income protection" are all refused today).
- Owner (only the owner, not the bot) adds terms with `ws_add_approved_term(workspace, vertical, kind, term)` and removes them with `ws_remove_approved_term(id)`; each change is audit logged without the term text. Removing a term does not rewrite stored rows.

### PROPOSAL ONLY: starter list for the owner and the client's compliance contact to accept, edit or reject (nothing below is enabled; the AI does not choose the list)
Scope suggestion: the client's workspace, or vertical `insurance` if more insurance clients follow. Each name must match a product the client is licensed to sell and the agency/MGA has cleared for advertising.
| Kind | Proposed terms | Notes |
|---|---|---|
| product (EN) | health insurance; extended health coverage; disability insurance; critical illness insurance; life insurance; term life insurance; whole life insurance; universal life insurance; long term care insurance; travel insurance; group benefits | confirm each against the client's licence and product shelf |
| product (FR) | assurance santé; assurance invalidité; assurance maladie grave; assurance vie; assurance vie temporaire; assurance collective | "assurance maladie grave" is the usual critical-illness product name; confirm with the client |
| place | Medicine Hat | the only place name known to trip the detector so far; add others only when one actually does |
| NOT proposed | terms that name a condition ("cancer insurance", "diabetes insurance"); anything with "income" ("disability income", "income protection": refused, not waivable); anything with a first-person word | named-condition products are a compliance question first |
Open question for the owner: if the client sells disability-income or income-protection products, say so; today the word `income` can never be approved (it is the mortgage-income category).

## Compliance guardrails to confirm with the client
1. Insurance advertising in Ontario: FSRA regulates insurance agents; O. Reg. 7/00 (Unfair or Deceptive Acts or Practices, under the Insurance Act) exists and governs misleading conduct. Title: https://www.ontario.ca/laws/regulation/r00007 (existence confirmed by search; operative wording NOT reviewed in this build). CONFIRM with the client's agency/MGA: required licence disclosures, titles, product claims and comparison rules in ads.
2. CASL consent for any outreach to leads or recruits: see Client 1 doc item 2 (source https://crtc.gc.ca/eng/com500/guide.htm). Recruiting messages to individuals are still commercial electronic messages when they encourage participation in commercial activity: CONFIRM scope with the client's counsel.
3. Meta special ad categories: recruiting ads are employment ads in Meta's terms, which must be declared for Canada and carry targeting restrictions (source https://developers.facebook.com/docs/marketing-api/audiences/special-ad-category ). Whether independent-agent recruiting counts as employment is NOT verified: CONFIRM with Meta policy. Client-acquisition life-insurance ads: category not verified.
4. Earnings, income or licensing-timeline claims in recruiting copy are high-risk. Do not draft them; CONFIRM what the client and agency allow.
5. Privacy of lead/recruit data (PIPEDA): not researched in this build. CONFIRM.

## Campaign architecture
Same tables as Client 1. Two campaigns are expected only if both acquisition and recruiting are confirmed; keep them as separate campaigns so reports stay clean. No creatives for a model that is not recorded.

## Reporting spec
Same weekly report. If recruiting is in scope, the owner defines what "booked" means (call, interview) before the lead-to-booked rate is trusted.

## Integrations
Same list as Client 1 (Meta account, landing page/form, client CRM or inbox, booking link, owner approvals). All need the client's own credentials; none are built.

## Open items for the owner
Recruiting model; client acquisition vs recruiting scope; budget; geography; CRM; sponsoring-agency sign-off route; consent wording; Meta category confirmation. Insurance wording (20261122): accept, edit or reject the PROPOSED term list above (nothing is permitted until the owner adds terms); decide whether income-bearing product names ever need a waiver; confirm lead notes stay strict. Every ad still goes through the client's agency/MGA sign-off; the classifier is a screen, not a compliance approval.
