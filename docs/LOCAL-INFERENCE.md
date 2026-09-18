# Local inference — Karakeep and Paperless

Where the fleet should run local models for Karakeep's tagging and Paperless's
OCR and classification, given the hardware it has and a $150 budget.

This is fleet-scoped because the governing question is *which machine owes the
compute*, and the answer is not necessarily the machine running the app — an
Ollama endpoint is an HTTP call, so the model can live anywhere on the tailnet.

Research only. Nothing here is deployed, and §7 lists what has to be measured
before any of it should be.

Dates are UTC. Prices are US street prices as of 2026-09-14.

---

## 1. The principle

> **Only one of these three jobs is a language-model job. Decide which is
> which before buying anything, because the other two are already solved by
> software the fleet is running today.**

The request bundles "local models for Karakeep" with "OCR and classifying
documents in Paperless" as though they were one workload. They are not, and
the difference is most of the answer:

| Job | Is it an LLM job? | What actually does it |
|---|---|---|
| **Karakeep auto-tagging** | ✅ **Yes** | Open-vocabulary tags over arbitrary web content. Genuinely needs a generative model. |
| **Paperless OCR** | ❌ **No** | Tesseract, via OCRmyPDF. Confirmed against upstream's `docs/configuration.md`: `PAPERLESS_OCR_*` configures Tesseract, and the AI settings are a separate section that does not touch it. |
| **Paperless classification** | ⚠ **Mostly no** | A built-in scikit-learn TF-IDF classifier trained on your own corrections. The LLM is an *addition* to it, not a replacement. |

⭐ **The LLM does not do OCR in Paperless and cannot be made to.** Vision-model
OCR exists only in third-party sidecars (paperless-gpt, Paperless-AIssist,
paperless-local-ai), and it is one to two orders of magnitude more expensive per
page than Tesseract. It buys something real on handwriting and bad scans and
nothing at all on the clean digital PDFs that dominate a personal archive.

⚠ **The corollary is that the budget question is smaller than it looks.** Two of
the three jobs need no accelerator at any price.

---

## 2. What each app asks the model to do

⭐ **Both apps run on galactica as Docker containers**, not via the nixpkgs
NixOS modules — `hosts/galactica/karakeep.nix` (karakeep `0.33.2`, plus a
headless Chrome and Meilisearch) and `hosts/galactica/paperless.nix`
(paperless-ngx `3.1.3`, plus a Valkey broker). First switch and data restore
are recorded in that host's `MANUAL-STEPS.md` §15.

That matters for configuration: every setting below is an **environment
variable on the container** (`virtualisation.oci-containers.containers.<name>.environment`,
or the sops env template for anything secret), not a `services.*.settings`
attribute. It also creates a networking trap — see §6.

### 2.1 Karakeep

Verified against upstream's environment-variable table. The inference settings
and their defaults:

| Variable | Default | Note |
|---|---|---|
| `OLLAMA_BASE_URL` | *unset* | Setting this (or `OPENAI_API_KEY`) is what enables tagging at all |
| `INFERENCE_TEXT_MODEL` | `gpt-5.6-luna` | ⚠ An OpenAI name. Left alone, Karakeep asks Ollama for a model it does not have |
| `INFERENCE_IMAGE_MODEL` | `gpt-4o-mini` | Optional; leave empty unless tagging images |
| `INFERENCE_CONTEXT_LENGTH` | `2048` | The single biggest cost knob (§4) |
| `INFERENCE_JOB_TIMEOUT_SEC` | `30` | ⚠ Sized for a hosted API. Fatal on CPU (§6) |
| `INFERENCE_ENABLE_AUTO_TAGGING` | `true` | |
| `INFERENCE_ENABLE_AUTO_SUMMARIZATION` | `false` | Leave off — it doubles the work per bookmark |
| `EMBEDDING_TEXT_MODEL` | `text-embedding-3-small` | Also an OpenAI name |

Shape of one job: a few thousand tokens of page text in, ~100 tokens of JSON
tags out. **Prefill-dominated, output-trivial, and asynchronous** — it is a
background worker, and nobody is watching a cursor blink.

### 2.2 Paperless-ngx

Built-in AI landed in the 3.x line, so the deployed `3.1.3` image has it:

| Variable | Default | Note |
|---|---|---|
| `PAPERLESS_AI_ENABLED` | `false` | |
| `PAPERLESS_AI_LLM_BACKEND` | *none* | `ollama` or `openai-like` |
| `PAPERLESS_AI_LLM_MODEL` | *none* | |
| `PAPERLESS_AI_LLM_ENDPOINT` | *none* | Required for the Ollama backend |
| `PAPERLESS_AI_LLM_EMBEDDING_BACKEND` | *none* | `ollama`, `huggingface`, `openai-like` |
| `PAPERLESS_AI_LLM_EMBEDDING_MODEL` | *none* | RAG/chat only |

⭐ **Suggestions work without an embedding backend.** Embeddings are needed only
for document chat and the archive-wide index — which is the one part of this
whole design that is a genuinely large batch job, and the one part that is
optional. **Start without it.**

⭐ **The LLM does not displace the classifier; they surface side by side.** So
the two are complementary rather than competing, and they fail in opposite
directions:

| | Built-in classifier | LLM suggestions |
|---|---|---|
| Cost | Trivial — TF-IDF, retrains nightly | Seconds to minutes per document on CPU |
| Cold start | ❌ Needs ~10+ documents per tag before it is useful | ✅ Correct on document #1 |
| Unseen correspondent | ❌ Cannot predict a class it has never seen | ✅ Zero-shot |
| Steady state on a labelled archive | ✅ Fast and accurate | Expensive, and rarely better |

**That table is the design.** Let the classifier carry the steady state; spend
model time only on the cold start and the genuinely novel document.

⭐ **Paperless's live archive is already on galactica** (`/tank/documents/paperless`,
a populated instance restored from the old Unraid setup, not fresh state). That
is an argument for galactica but not a decisive one: the LLM call is HTTP, so
the model may sit on another host without the documents ever leaving this one.

---

## 3. The three candidate machines

The constraint is galactica, memory-alpha, or a Raspberry Pi 5 8 GB.

Generation speed on CPU is bounded by **memory bandwidth ÷ model size**, which
is arithmetic rather than opinion. Prefill is bounded by vector-matmul
throughput, which is where instruction sets matter.

| | **galactica** | **memory-alpha** | **Pi 5 8 GB** |
|---|---|---|---|
| CPU | Xeon E3-1230 v2, 4C/8T (2012) | Tiger Lake UP3, 4C/8T | Cortex-A76 ×4 @ 2.4 GHz |
| Vector ISA | AVX — ⚠ **no AVX2** | **AVX-512 + VNNI** | NEON (no SVE) |
| RAM | 32 GB DDR3-1333 ECC, dual channel | 32 GB DDR4-3200, dual channel | 8 GB LPDDR4X-4267, 32-bit |
| **Bandwidth** | **21.3 GB/s** | **51.2 GB/s** | **17.1 GB/s** |
| Thermals | Tower, server cooling, headroom | ⚠ 15–28 W in a printed case | ⚠ Needs active cooling |
| Contention | ⚠ Now runs both apps plus the *arr stack | ⚠ Jellyfin + Quick Sync + aarch64 builds | None (new host) |
| PCIe | ⚠ 4 slots — see §5 | ❌ **None** — Framework mainboard | ❌ None |

Sources for the hardware facts: `hosts/galactica/PLATFORM.md` §9 (the CPU's
missing AVX2) and §11, `hosts/galactica/hardware-profile-2026-08-31.txt`,
`hosts/memory-alpha/HARDWARE-MAP.md` §4.

### Expected throughput for a 4B model at Q4_K_M (≈ 2.5 GB)

The ceiling column is bandwidth ÷ 2.5 GB and is hard arithmetic. The realistic
column applies the ~50–60 % of ceiling that CPU llama.cpp actually achieves —
⟨extrapolated, not measured on these boxes; §7⟩. The extrapolation is calibrated
against published Pi 5 figures of 4–6 tok/s for a 3B Q4 model, which is ~60 % of
that configuration's 8.5 tok/s ceiling.

| | Generation ceiling | Realistic generation | Prefill |
|---|---|---|---|
| memory-alpha | 20 tok/s | **8–12 tok/s** | Best of the three — VNNI does real work here |
| galactica | 8.5 tok/s | **4–5 tok/s** | ⚠ Worst — no AVX2 means llama.cpp falls back to SSE paths |
| Pi 5 | 6.8 tok/s | **3–4 tok/s** | Middling |

⭐ **memory-alpha is roughly 2–3× the other two and is the only one whose
advantage shows up in prefill as well as generation** — which is the half that
matters, because §2 established both workloads are prefill-dominated.

⚠ **Both real candidates are contended, in different ways.** memory-alpha's own
`HARDWARE-MAP.md` §4 warns that CPU inference, Quick Sync and Jellyfin
transcoding all draw on the same 15–28 W package budget, that nothing in its
config manages thermals today, and that sustained multi-hour load is untested on
it. galactica has the thermal headroom but is no longer the idle box it was
before the apps landed — it now carries Karakeep's three containers, Paperless's
two, and the media stack.

---

## 4. Sizing the actual work

One item ≈ 3 000 tokens of prefill + ~100 tokens out. At the figures above:

| | Per item | 50 items/day | Backlog of 2 000 |
|---|---|---|---|
| memory-alpha | ~1–2 min | 1–2 h | **1.5–3 days** |
| galactica | ~3–5 min | 2.5–4 h | **4–7 days** |

**Steady state is comfortable on either.** Both fit in an overnight window with
room to spare. `modules/nixos/olla-router.nix` already carries an
`ollama-batch` timer firing at 02:00 for this shape of job — ⚠ though its
`ExecStart` is still an explicit TODO stub, so the schedule exists and the work
does not.

**The backlog is the only hard part**, and it is one-time. That reframes the
host choice: galactica's slowness costs a few extra days *once*, on the box that
already holds both apps' data and has the thermal headroom to grind;
memory-alpha's speed is paid for with thermal risk on the one machine whose
sustained behaviour is a documented unknown.

⭐ **`INFERENCE_CONTEXT_LENGTH` is the cheapest lever in the whole design.**
Cost is near-linear in prefill tokens, so halving 2048 → 1024 nearly halves the
bill; raising it to 8192 quadruples it. Tag quality rises with context, but the
first ~1 000 tokens of a web page carry most of what a tagger needs.

---

## 5. The $150 — and why it should not be spent

⚠ **This is the finding that changes the answer.** The budget was set against
pre-2026 prices. The DRAM and GPU shortage has moved every relevant number:

| Option | Price now | Verdict |
|---|---|---|
| **Raspberry Pi 5 8 GB** | MSRP $95 after two hikes; street ~$180–220 | ❌ Slowest of the three, costs money, adds a host to maintain. LPDDR4X rose ~7× in a year |
| **Intel Arc A380 LP 6 GB** | ~$139 | ❌ See below — the only card in budget, and it almost certainly cannot be seated |
| RTX 3060 12 GB used | ~$280 | ❌ Out of budget |
| Tesla P40 24 GB used | ~$200–240 | ❌ Out of budget, passive cooling, no tensor cores |
| RTX 3060 Ti 8 GB used | ~$200–220 | ❌ Out of budget |

### Why the Arc A380 fails, specifically

It is the only accelerator inside $150, so it deserves the autopsy.

**What the tree actually records.** SMBIOS
(`hardware-profile-2026-08-31.txt`, DMI type 9) reports four slots:

| Designation | Type | Data Bus Width | Usage |
|---|---|---|---|
| SLOT 4 | PCI Express 2 | x4 | Available |
| SLOT 5 | PCI Express 2 | x4 | In Use |
| **SLOT 6** | **PCI Express 3** | **x8** | **Available** |
| SLOT 7 | PCI Express 3 | x8 | In Use |

⚠ **Two corrections to how this data is easy to misread.** `Length: Short` on
all four entries means *card length* (half-length), **not** lane width — the
widths are the `Data Bus Width` column above. And these are **electrical**
widths; SMBIOS says nothing about the physical connector. Note also that
`PLATFORM.md` §7b twice lists the slot electrical widths as an open gap citing
`HARDWARE-MAP.md` §4 — the SMBIOS dump above in fact answers that, and
reconciling the two is a separate cleanup this document does not attempt.

**The blockers:**

1. ⚠ **It probably does not physically fit — and this is the claim to check
   first.** The A380 is PCIe 4.0 ×8 electrically but carries a **physical x16
   connector**, and Intel's stated requirement is a full-size x16 slot.
   Supermicro's manual and third-party reviews of the X9SCM-F describe its four
   slots as all physically x8; `PLATFORM.md` §10 records them as "four PCIe
   slots, visually confirmed identical". ⟨**This rests on external sources, not
   on the tree.** One look inside the case settles whether any slot is
   open-ended — do that before spending anything.⟩
2. ⚠ **No Resizable BAR.** Arc is architecturally dependent on ReBAR in a way
   NVIDIA and AMD are not — Intel treats it as required, not as a bonus.
   Galactica's BIOS is AMI Aptio from 2012 (revision `2.3a`, `PLATFORM.md` §11).
   ReBAR is not there, and modding it in would mean a BIOS flash on the storage
   host. **This blocker holds regardless of how blocker 1 resolves.**
3. **Slot contention.** `PLATFORM.md` §7b commits both CPU slots to the LSI HBA
   and a planned 10G NIC, with the NVMe conceded to PCH on DMI grounds. SLOT 6
   is the only Gen3 x8 slot free, and it is the one that plan wants. PSU headroom
   is ⟨unrecorded anywhere in the tree⟩.

**And there is no GPU path on the other two at all.** memory-alpha is a
Framework mainboard with no PCIe slot — its expansion is USB4/Thunderbolt, and a
used TB3 eGPU enclosure alone exceeds $150 before any card goes in it. The Pi 5
has no slot either.

> ### Recommendation: spend $0.
>
> $150 in September 2026 buys either the slowest of the three candidate machines
> or a card that ReBAR rules out of the only machine with a slot. The fleet
> already owns hardware that does this job adequately, and the workload is batch
> and latency-tolerant. Bank the money until memory prices normalise — at which
> point the right purchase is a 12 GB card, not a 6 GB one.

---

## 6. The configuration traps

Known failure modes, worth recording before anyone spends an evening on them:

1. ⚠ **Both apps are containers on their own Docker networks.** `karakeep.nix`
   and `paperless.nix` each create a dedicated user-defined bridge so the
   containers can resolve each other by name. An Ollama on the host bound to
   `127.0.0.1` — which is what `modules/nixos/ollama.nix` does, deliberately —
   **is not reachable from inside those containers.** `OLLAMA_BASE_URL` and
   `PAPERLESS_AI_LLM_ENDPOINT` must point at an address the container can
   actually route to: the bridge gateway, a tailnet address, or an Ollama
   container attached to the same networks. This is the first thing that will
   break and the least obvious from the error message.
2. ⚠ **`INFERENCE_JOB_TIMEOUT_SEC` defaults to 30 seconds.** §4 puts one CPU job
   at one to five *minutes*. Every job fails until this is raised. Upstream also
   reports a separate hard 5-minute ceiling that a raised value does not lift,
   and it fails silently — so keep per-job work under five minutes regardless,
   which is another argument for a small model and a short context.
3. ⚠ **`INFERENCE_TEXT_MODEL` defaults to an OpenAI model name.** Pointed at
   Ollama and left alone, Karakeep asks for a model that is not there. The
   symptom is a confusing "wrong model" error, not a clear misconfiguration.
4. ⚠ **Strict JSON-schema structured output breaks small local models.** They
   stall for minutes or emit malformed output. Prefer plain output and let
   Karakeep parse it.
5. **`services.ollama.package` selects acceleration**, not a removed
   `acceleration` option. `pkgs.ollama` is the CPU build; `ollama-vulkan` would
   target memory-alpha's Iris Xe. ⚠ The iGPU shares the same DDR4 controller, so
   it cannot raise the generation ceiling in §3 — it can only help prefill, and
   it contends directly with Jellyfin's Quick Sync.

---

## 7. Proposed shape, and what must be measured first

**Nothing here is deployed.** The order below is deliberate: each step is
useful on its own and the expensive ones come last.

1. [x] ~~Re-home Paperless and Karakeep with OCR and the classifier only — no
   LLM.~~ **Done 2026-09-13** — both are live on galactica (`MANUAL-STEPS.md`
   §15). Tesseract handles OCR and the scikit-learn classifier handles tagging,
   which is most of the value at none of the cost, and the labelled corpus the
   classifier needs is already accumulating.
2. [ ] **Measure before choosing a host.** Run `llama-bench` with a 4B Q4_K_M on
   both galactica and memory-alpha and replace §3's extrapolated column with
   real numbers. ⚠ On memory-alpha, watch package temperature through the first
   hour — `HARDWARE-MAP.md` §4 lists sustained thermal behaviour as an open
   question, and this is the job that answers it.
3. [ ] **Stand up Ollama on the winner**, CPU-only, one small model. Qwen3.5 4B
   at Q4_K_M is the current consensus pick for structured extraction on CPU;
   Gemma 4 E2B is the fallback if 4B proves too slow.
4. [ ] **Solve §6's container-networking question once**, and record the answer
   — both apps need it and it is the same answer for both.
5. [ ] **Point Karakeep at it**, with §6's traps pre-empted and
   `INFERENCE_CONTEXT_LENGTH` tuned from a real sample rather than guessed.
6. [ ] **Enable `PAPERLESS_AI_ENABLED` last**, suggestions only, **no embedding
   backend**. Revisit RAG/chat only once §3's numbers are real.
7. [ ] **Look inside the case** before reconsidering any GPU — §5's blocker 1 is
   an external claim, and PSU headroom is unrecorded.

### The tension worth naming

⭐ **`modules/nixos/olla-router.nix` already has a placeholder slot for exactly
this.** Its config carries a `gpu1070-node` endpoint at priority 50 behind
pegasus's 4070 at priority 100, with health-check failover that drops an
endpoint when its Ollama goes down.

That is the right architecture for this problem, and it is already written.
A CPU endpoint on galactica or memory-alpha would drop into the priority-50
slot: Karakeep and Paperless address Olla and never learn which machine served
them, the 4070 takes the work whenever pegasus is up and not gaming, and the
always-on CPU endpoint catches everything else.

⚠ **This research was scoped to exclude pegasus**, so the design above stands on
its own without it — the CPU endpoint alone satisfies both apps at the rates in
§4. But the exclusion is worth revisiting explicitly rather than by default:
pegasus is the one machine in the fleet that makes the §4 backlog a few hours
instead of a few days, and the failover plumbing that would make its
intermittent availability safe is already in the tree.

---

## 8. Sources

Hardware and deployment facts come from this repo
(`hosts/galactica/PLATFORM.md`, `hosts/galactica/hardware-profile-2026-08-31.txt`,
`hosts/galactica/{karakeep,paperless}.nix`, `hosts/galactica/MANUAL-STEPS.md` §15,
`hosts/memory-alpha/HARDWARE-MAP.md`). External claims:

- Karakeep configuration reference — <https://docs.karakeep.app/configuration/environment-variables/>
- Karakeep AI providers — <https://docs.karakeep.app/configuration/different-ai-providers/>
- Paperless-ngx configuration reference — <https://docs.paperless-ngx.com/configuration/>
- Paperless-ngx advanced usage (the classifier) — <https://docs.paperless-ngx.com/advanced_usage/>
- Raspberry Pi price rises — <https://www.raspberrypi.com/news/more-memory-driven-price-rises/>
  and <https://www.theregister.com/2026/02/02/raspberry_pi_ram_shortage_price_hike/>
- Used GPU pricing — <https://gpudojo.com/> and <https://resaleprices.com/gpu/nvidia-rtx-3060>
- Intel Arc ReBAR requirement — <https://www.intel.com/content/www/us/en/support/articles/000090831/graphics.html>
  and <https://www.hwcooling.net/en/intel-arc-graphics-require-pcie-resizable-bar-for-performance/>
- Arc A380 specifications — <https://www.intel.com/content/www/us/en/products/sku/227959/intel-arc-a380-graphics/specifications.html>
- X9SCM-F slot layout — <https://www.supermicro.com/manuals/motherboard/C202_C204/MNL-1270.pdf>
  and <https://www.servethehome.com/supermicro-x9scmf-sandy-bridge-xeon-lga1155-c204-motherboard-review/>
- Pi 5 llama.cpp figures — <https://tinyweights.dev/posts/run-llms-raspberry-pi-5/>
