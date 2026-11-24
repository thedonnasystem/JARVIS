# Sources and labels used in growth/donna

Every benchmark in these docs cites one of the sources below as `[S#]`. Anything without a source is marked:

- **[ASSUMPTION]**: our planning number. No data behind it yet. Replace it with your own tracker numbers after 7 days.
- **[OWNER: confirm]**: a business, legal or money decision only the owner can make.
- **[VERIFY]**: a fact we could not re-check in this session. Check it before you rely on it.

Prices are USD unless marked CAD. Donna.AI prices are CAD.
Most benchmark sources sell software in the space, so treat them as rough guides, not truth.

| # | Source | What we use from it |
|---|---|---|
| S1 | Invoca, "How much missed sales calls cost home services businesses", 2024-05-23. https://invoca.com/blog/how-much-missed-sales-calls-cost-home-services-businesses | 27% of calls to home services businesses are not answered (Invoca research, method not published). Under 3% of callers sent to voicemail leave a message (Invoca platform data). |
| S2 | CallRail, "How missed calls are costing your business", 2025-09-11. https://www.callrail.com/blog/missed-calls-costing-your-business | 28% of calls to businesses go unanswered (CallRail beta participant data). Cites LeanData: 78% of customers buy from the first company that responds. |
| S3 | Instantly, "Cold Email Benchmark Report 2026", updated 2026-01-12 (data Jan 1 to Dec 18, 2025). https://instantly.ai/cold-email-benchmark-report-2026 | Average reply rate 3.43%. Top quartile 5.5%+. Elite 10%+. Step 1 brings 58% of replies, follow-ups 42%. 4 to 7 touches, 3 to 4 days apart. |
| S4 | Belkins, "B2B cold calling statistics 2026", 2026-06-26 (175,000+ dials in 2025). https://belkins.io/blog/cold-calling-benchmarks | 9.9% of dials reach a person. 4.6% of conversations book a meeting. About 370 dials per meeting. This is B2B office calling; owner-operated trades answer differently, so we use our own assumptions next to it. |
| S5 | LocaliQ, "Home services advertising benchmarks", data May 2020 to Jun 2021, page updated 2026-02-23. https://localiq.com/blog/home-services-advertising-benchmarks/ | Google Search cost per lead: HVAC (AC services) $55.15, plumbing $48.91, roofing $101.49 (USD, medians, 4,595 accounts). Old data. |
| S6 | PPC Land on WordStream's 2026 Facebook Ads Benchmarks, 2026-09-14. https://ppc.land/facebook-lead-costs-hold-at-27-39-as-traffic-clicks-drop-to-0-60/ | Facebook median cost per lead $27.39 (all), Home and Home Improvement $42.95 (USD, 452 US campaigns). |
| S7 | Housecall Pro, "Local Services Ads guide", 2026-05-07. https://www.housecallpro.com/learn/local-services-ads-guide/ | Google Local Services Ads: most home service businesses pay $25 to $130+ per lead (citing Blue Grid Media). Pay per lead. Disputes within 30 days. |
| S8 | Niagara Stands Out, "Google LSA for contractors (Canada 2026)", 2026-02-15. https://niagarastandsout.ca/blogs/business-resources/google-local-services-ads-for-contractors-pay-per-lead-guide-canada-2026 | LSA in Canada covers trade categories such as HVAC, plumbing, electrical and roofing. $20 to $80 per lead. Suggested start budget $500 to $1,000 a month. |
| S9 | CRTC, "CASL guidance on implied consent". https://crtc.gc.ca/eng/com500/guide.htm | Implied consent from a conspicuously published address applies only if (1) no "no unsolicited messages" statement is published with it, and (2) the message relates to the person's business role. The sender must prove it: keep a dated screenshot and the URL. Unsubscribes must be honoured within 10 business days. Every CEM needs identification and an unsubscribe mechanism. |
| S10 | Competition Bureau, "Warranties and guarantees". https://competition-bureau.canada.ca/en/node/50 | s.74.01(1)(c): a guarantee is reviewable if it is misleading or there is no reasonable prospect it will be carried out. Courts use the "general impression" test. Penalties up to $10M for a corporation (first order), or 3x the benefit. |
| S11 | Competition Bureau, "Performance claims not based on an adequate and proper test". https://www.competitionbureau.gc.ca/eic/site/cb-bc.nsf/eng/00520.html [VERIFY: not opened in this session] | s.74.01(1)(b): a claim about how a product performs must be tested before it is made. |
| S12 | Google, "Guidelines for representing your business on Google". https://support.google.com/business/answer/3038177 | Eligible only with a location customers visit, or travel to customers. Service-area businesses hide the address. Service area about 2 hours' drive. The name must be the real-world name, no taglines or keywords. Use as few categories as possible ("this business IS a..."). |
| S13 | Upwork, "Is Upwork free?" (2026). https://www.upwork.com/resources/is-upwork-free | Freelancer fee 0 to 15%. Connects $0.15 each. Freelancer Plus $19.99/month. |
| S14 | Competition Act, s.74.01. https://laws-lois.justice.gc.ca/eng/acts/C-34/ | Misleading representations, performance claims, guarantees, ordinary-price claims. |
| S15 | `docs/research/donna_competitors_2026.md` (this repo, 2026-11-23) | Competitor prices, the weak risk reversal across the market, Smith.ai's money-back guarantee capped at $1,000, Podium's 12-month lock-in. |
| S16 | Google Maps user-contributed content policy (fake engagement). https://support.google.com/contributionpolicy/answer/7400114 [VERIFY: the page did not open in this session] | No paying or rewarding people for reviews. No asking only happy customers (review gating). No reviews from staff, family or friends posing as customers. |
| S17 | Competition Bureau, "Make sure your Black Friday deals are real", 2025-11-25. https://www.canada.ca/en/competition-bureau/news/2025/11/businesses-make-sure-your-black-friday-deals-are-real.html | The founding price compared with an *upcoming* standard price stays truthful only if new clients really pay the standard price later. |

Blocked in this session (not used): `99calls.com` LSA cost per industry, `wordstream.com` 2026 benchmark page (fetch failed).
