# Pipeline tracker: what to track from day 1

One row per business. Start it as a Google Sheet built from [pipeline_tracker.csv](pipeline_tracker.csv) (header row plus one **fictional** example row; delete the example).

**Privacy:**
- The tracker holds real contacts, so **keep it out of this repo**.
- Share it only with reps who need their own rows.
- Delete a contact's details when they ask.

## Stages
| # | Stage | Exit rule (what moves a row forward) |
|---|---|---|
| 0 | New | Added with a source |
| 1 | Audited | At least 1 audit call logged (daytime or after hours) |
| 2 | Contacted | First outreach made (call, walk-in, email, DM, warm message) |
| 3 | Conversation | Spoke with the owner or decision-maker, live or by a real two-way exchange |
| 4 | Review booked | 15-minute audit review or demo on the calendar |
| 5 | Review held | Audit shown, demo line heard, offer made |
| 6 | Pilot / thinking | Paid pilot running ([RISK_REVERSAL.md](RISK_REVERSAL.md) option B, if approved), or a decision date agreed |
| 7 | Won | Agreement signed **and** first payment received |
| 8 | Live | Forwarding on after test-line approval (onboarding: `build/donna-launch`) |
| L | Lost | The reason is required (`lost_reason`) |
| N | Nurture | Not now. `next_action_date` is required. |
| X | Do not contact | Asked to stop. Kept only to honour the request; no other details kept beyond that. |

## Columns
| Column | What to put in it | Why |
|---|---|---|
| `lead_id` | D-0001, D-0002 ... | Unique key |
| `date_added` | YYYY-MM-DD | Ageing |
| `owner` | Moe or the rep's name | Commission and accountability |
| `source_channel` | warm, outbound_call, walk_in, cold_email, dm_ig, dm_fb, fb_group, partner, referral, linkedin, content, gbp, marketplace, event, paid_meta, paid_google, website_form, demo_line | Channel ranking |
| `source_detail` | Who referred, which group or post, which partner | Pay partners, repeat what works |
| `vertical` | home_services, real_estate, med_spa_beauty, auto, law, clinic, cleaning_landscaping, other:... (add the trade in `notes`) | Effort split and day-7 rebalance |
| `size` | Trucks, chairs, agents or staff: 1, 2 to 3, 4 to 10, 10+ | Fit |
| `city` | Service city | Territory |
| `business_name`, `contact_name`, `role`, `phone`, `email`, `website` | As published or as given | Contact |
| `consent_basis` | personal_relationship, referral, express, implied_published, existing_business_relationship, none | CASL: email and DM only with a basis [S9] |
| `consent_evidence` | URL plus screenshot file name plus date checked | CASL burden of proof [S9] |
| `unsubscribed_date` | YYYY-MM-DD | Stop within 10 business days; same day in practice [S9] |
| `stage` | 0 to 8, L, N or X | Funnel |
| `stage_date` | Date the current stage was reached | Speed |
| `audit_day_datetime`, `audit_day_result` | When and what: answered, voicemail, no_answer, rang_out, full_mailbox | Proof for the pitch |
| `audit_after_hours_datetime`, `audit_after_hours_result` | Same | The strongest proof |
| `callback_minutes` | Minutes until they called back, or "none" | Speed-to-lead proof |
| `demo_line_heard` | Y/N | Every touch should get to Y |
| `calc_estimate_month` | Calculator estimate of revenue lost per month (CAD), labelled as an estimate | Value framing |
| `package_interest` | answer, capture, command, site, site_pro | Revenue forecast |
| `mrr_potential` | 497, 797, 1297 | Revenue forecast |
| `touches` | Count | Persistence |
| `last_touch_date`, `last_touch_type` | Date plus call, walk_in, email_1 ... | Cadence |
| `next_action`, `next_action_date` | Required on every open row | Nothing falls through |
| `objection` | price, already_have, no_missed_calls, ai_doubt, timing, partner, other | Coaching |
| `lost_reason` | Same list plus no_fit, no_response | Learning |
| `offer_made` | Y/N plus date | Close-rate denominator |
| `risk_reversal_used` | none, audit_testline, pilot, booking_promise | Only approved options |
| `won_date`, `first_payment_date`, `founding_spot_no` | | Founding-spot records (dated, for Competition Act truthfulness [S17]) |
| `golive_date` | | 30-day windows |
| `referral_asked_date`, `referrals_given` | | Client #1 referral ask |
| `notes` | Free text, short | |

## Daily numbers (one summary row a day)
`date, audits_day, audits_after_hours, owner_dials, conversations, walk_ins, reviews_booked, reviews_held, offers, wins, warm_msgs, dms, emails, partner_touches, posts`

## Weekly views
- **Funnel by channel and by vertical:** count rows by `source_channel` × `stage`, and by `vertical` × `stage`.
- **Rates:**
  - conversation to review booked;
  - booked to held;
  - held to won.
- These replace the [ASSUMPTION] rates in [LAUNCH_48H.md](LAUNCH_48H.md) on day 7.
- **Audit miss rate per vertical:** share of audited lines with at least one voicemail, no answer or rang out. It drives the day-7 rebalance.
- **Founding spots used** (out of 10), with dates.
