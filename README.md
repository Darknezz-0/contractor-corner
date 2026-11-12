# Contractor Corner

Simple quote-to-cash web app for solo contractors — handyman, lawn, cleaning, any trade.
Phone-first web app: open in a browser, add to home screen, no app-store download.

## What v1 does
- Public signup (email + password, no invite code) — lands on Free automatically
- Send a quote/estimate from your phone; customer approves
- Field view (simple, big buttons) and office view (full detail) — same jobs, same status
- Turn a quote into an invoice with one tap, no retyping
- Record payments (cash / card in person / bank / check), deposit or full amount, who paid / who still owes
- Profit per job: price minus materials minus time
- Before-and-after photos kept with the job; voice note on the job
- Simple day calendar, customer list (name, address, phone, what was done last time)
- Job status: Lead / Estimate Sent / Approved / Scheduled / Done / Paid
- CSV export of all jobs; print / save invoice as PDF
- Free tier: 5 jobs a month. Paid (planned price, not final): $19/month early/founding, $29/month regular — unlimited jobs, missed-call text-back, late-payment reminders, automatic review asks, full calendar & customer list

## What v1 does NOT do (by design)
- No real Stripe charges — payments are recorded in the app; live card payments come later (Stripe takes about 2.9% + 30¢ per payment when added)
- No dispatch boards, GPS fleet tracking, marketing suites, blueprint takeoffs, subcontractor portal, client financing, AI renderings, per-user pricing, or QuickBooks replacement
- No server backend yet — accounts and jobs are saved in the browser on the device (localStorage). A shared server account + database is the next step before real multi-device use.

## Tech
Static single-page app: `index.html` only, no build step, no dependencies. Deploy anywhere static hosting works (Vercel).

## Run locally
Open `index.html` in a browser, or serve it: `python3 -m http.server` in this folder.
