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

## Insurance product wording versus personal health information (20261122, default-deny)
Ordinary product wording ("health insurance", "disability insurance", "critical illness insurance", "assurance santé", "assurance invalidité", "Medicine Hat") used to be refused by the health detector. It is now permitted ONLY in this form, on non-person tables (campaign names, ad sets, creatives, approvals, onboarding values, ledger notes):
1. **Owner-approved terms** in `ws_approved_terms` (shipped EMPTY): `product` names, `feature` phrases (generic coverage descriptions that may name conditions) and `place` names (chosen from the fixed municipality catalog `ws_place_catalog`);
2. **plus the owner-managed generic vocabulary** `ws_marketing_vocab` (about 900 en/fr function and marketing words, shipped with the migration; generic only);
3. **plus numbers, prices, percentages, age ranges and simple punctuation.**
Any other word in insurance-related text is refused (`unknown_word`), whatever it means: names, relations ("client", "mother", "wife"), pronouns, narrative ("has", "took", "lost", "claim approved"), conditions, medications, body parts, other scripts. With no approved term the old fail-closed behaviour applies unchanged. Full model, limits and decision order: `DATA_CLASSIFICATION_AND_BACKUP_POLICY.md` section 5a.
- Allowed once approved (examples that pass in the test corpus of 100+ sentences): "Protect your family with health insurance", "Canada's #1 health insurance broker", "Health insurance in 1 minute", "1 in 3 Canadians need disability insurance", "Health insurance @ $25/mo", "Disability insurance can cover up to 70% of your income", "Critical illness insurance covers heart attack, stroke and cancer", "Life insurance for non-smokers", "Assurance maladie grave", "Assurances santé", "Assurance invalidité : jusqu'à 70 % de votre revenu".
- Always refused: personal medical information in any wording ("client has lupus", "she broke her leg", "is on ODSP"), anything about a named person or policy ("Life insurance application for Jean Tremblay is pending underwriting", "beneficiary is his wife", "rated table 4"), any phone, email, postal code, street address, date or 4+ digit number next to insurance wording, SIN / ID / banking / credit, policy or claim numbers, any "income" other than the generic "your income" (no amount) or an approved product phrase.
- Lead records (`ws_leads`) and workspace names stay strict: a lead note such as "interested in health insurance" is still refused. Record the interest in the client's own CRM.
- Writing rules: draft copy from vocabulary words only, with approved product names. Words that look harmless but are not vocabulary (a brand or agency name, "push", "spend", "healthy", "wellness", "Mon-Fri" (write "Monday to Friday"), "claim", "approved", "cannot work", emoji, `&`) are refused until the owner adds a vocabulary word or approves a feature phrase. An onboarding value that mentions insurance must be vocabulary-only (keep agency names and licence numbers in the client's own system).
- The owner (only the owner; the bot is refused) manages the lists: `ws_add_approved_term(workspace, vertical, kind, term, confirm_vertical)`, `ws_remove_approved_term(id)`, `ws_add_vocab_word(lang, word)`, `ws_remove_vocab_word(id)`. A vertical-wide term needs `confirm_vertical = true`. Each change is audit logged without the text. Product terms may not contain a condition, person, name or targeting phrase; feature phrases may name conditions but never a person; the vocabulary has a hard deny list. Removing a term does not rewrite stored rows.

### PROPOSAL ONLY: starter lists for the owner and the client's compliance contact to accept, edit or reject (NOTHING below is enabled; the migration ships the term tables empty and the AI does not choose the list)
Scope suggestion: the client's workspace, or vertical `insurance` (with the confirm flag) if more insurance clients follow. Each name must match a product the client is licensed to sell and the agency/MGA has cleared for advertising.
| Kind | Proposed entries | Notes |
|---|---|---|
| product (EN) | health insurance; extended health coverage; disability insurance; disability income insurance; income protection; income protection insurance; critical illness insurance; critical illness cover; life insurance; term life insurance; whole life insurance; universal life insurance; mortgage life insurance; long term care insurance; travel insurance; dental insurance; group benefits | confirm each against the client's licence and product shelf; "income" is accepted only inside a product phrase |
| product (FR) | assurance santé; assurances santé; assurance invalidité; assurance d'invalidité; assurance maladie grave; assurance vie; assurance vie temporaire; assurance collective; assurance voyage | "assurance maladie grave" is the usual critical-illness product name; confirm with the client |
| feature | heart attack, stroke and cancer; non smokers; no medical exam; non fumeurs; examen médical | generic coverage descriptions; a feature phrase makes the condition words usable ONLY as that exact phrase and only next to a product term. Approve only phrases the client's agency has cleared |
| place | Ottawa; Gatineau; Toronto; Calgary; Medicine Hat (any municipality of the catalog) | pick only the places the client actually advertises in |
| vocabulary | already seeded: articles, prepositions, pronouns you/your/vous/votre/we/nous, verbs such as protect/cover/pay/save/get/call/learn/compare/apply/quote, nouns such as family/business/price/month/year/coverage/protection/plan/quote/benefits, numbers words, days, provinces. Likely owner additions as real copy meets over-blocks: brand words, "revenue", "spend", "push" | each addition is an owner action; person, narrative, claim and health words can never be added |
| NOT proposed | terms that name a condition or a group of people with a condition ("cancer insurance", "diabetes coverage", "insurance for people with cancer"); anything naming a person; first-person or third-person wording; claim/underwriting wording | refused by the functions anyway; named-condition products are a compliance question first |

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
Recruiting model; client acquisition vs recruiting scope; budget; geography; CRM; sponsoring-agency sign-off route; consent wording; Meta category confirmation. Insurance wording (20261122, default-deny): accept, edit or reject the PROPOSED product, feature, place and vocabulary lists above (nothing is permitted until the owner adds terms); decide vertical-wide versus per-workspace scope; decide whether income-bearing product names are approved; confirm lead notes stay strict. Every ad still goes through the client's agency/MGA sign-off; the classifier is a screen, not a compliance approval.
