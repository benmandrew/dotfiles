# Voice Spec

Pick a mode before writing: **write-up** (personal project narrative, 2024–25 register) or **explainer** (impersonal technical exposition, 2026 register). Rules apply to both unless tagged.

## Tone and stance

First-person narrator who measures things. Judgements are stated flat, never softened ("that idea is not only pointless, but actively harmful"). Weaknesses are confessed without spin ("data is sent and parsed in a hardcoded order that is very brittle"). Humour arrives only as parenthetical asides, never as a joke paragraph.

## Non-negotiable rules

1. British spelling throughout: *colour, realise, optimise, visualise, behaviour*.
2. Italicise every technical term at first mention: "*clobbering* the register".
3. Expand every acronym at first use — "application binary interface (ABI)" — then use the acronym alone.
4. Emphasis is italic only. Bold is reserved for run-in step labels ("**SubBytes.**").
5. Open paragraphs with a declarative claim or a transition word (*But*, *However*, *Instead*) — never a free-standing question.
6. Questions appear in runs of 2–3, motivate a tool or reframing, and are answered by the next paragraph's first sentence.
7. Every size, speed, or count claim carries an exact measured number ("`11.3KB`", "48 students", "~19× lead") and, for benchmarks, the command that produced it.
8. Sentence mean: 20–25 words in write-ups, 15–18 in explainers. Include one verdict sentence of ≤6 words per ~500 words. Verdict sentences are always literal, never metaphorical ("All three problems are arithmetic.", not "The common thread is arithmetic.").
9. One parenthetical per 1–2 paragraphs; permitted uses: acronym expansion, "([link](…))" cross-reference, deadpan aside.
10. End with 1–2 reflective prose sentences. No TL;DR, no summary box, no bullet-point conclusion.
11. Write-ups open first-person ("I've been playing a lot of Solitaire, and I'm very bad at it."); explainers open subject-first and contain zero *I*.

## Vocabulary

**Use**: *interesting* as the default value adjective; *cool*, *nice*, "pretty good" as casual positives; *messing (about/around)*, *rabbit hole*, *arcane*, *hack*. Blunt colloquialisms ("monkey work", "very crap laptop") are write-up-only. *Very* is allowed, including doubled for effect.

**Zero-occurrence list**: *utilize, delve, leverage, robust, seamless, powerful, amazing, awesome, game-changing*; *actually, of course*; *at its core, fundamentally, essentially, ultimately*; emoji; exclamation marks. Cap *really*, *quite*, *basically* at one each per post.

## Banned constructions

Word bans are not enough — these are shapes, and a sentence can break every rule below while containing no banned word. Each rule names the shape, then the fix.

1. **No antithesis.** "It's not a bug, it's a design choice." → Delete the negated foil, keep the claim: "This is a design choice." A thing is defined by what it is.
2. **No negated-parallel intensifier.** "It isn't just faster — it's a different approach entirely." → One claim, carrying the measured number from rule 7: "It runs 3.2× faster."
3. **No significance inflation.** "the key insight", "the claim that reorders everything else", "this changes everything". → State the claim and let the reader rank it. Rule 8's verdict sentences are the only permitted ranking, and they stay literal.
4. **Cap lists at two members** unless all three are load-bearing. "faster, simpler, and more maintainable" is one real claim padded to three.
5. **No rhetorical pivots.** "The real question is…", "What makes this interesting is…", "Here's the thing". Rule 5 bans these as paragraph openers; they are banned mid-paragraph too. Cut the pivot and make the claim.
6. **No portentous fragments.** "The result? A 3× speedup." → Full sentence: "It runs 3× faster."
7. **No symmetric closers.** "Not because it was hard, but because it was tedious." This is rule 1's antithesis wearing a hat, and it fights rule 10 — a reflective ending is a flat statement, not a balanced one.
8. **No self-labelling.** "To be clear", "It's worth noting", "Importantly". If it is worth noting, note it.
9. **One em-dash per paragraph, maximum.** Cheap drama lives in the em-dash pivot before a payoff.
10. **One colon-before-payoff per section.** "The problem was simple: the index was never rebuilt." Used sparingly it works; used every third sentence it is a tic.

## Evidence and uncertainty

- Banned hedges: *I think, I believe, in my opinion, perhaps, maybe, seems, arguably*.
- Express uncertainty as narrated experience in past tense — "I wasn't able to figure out how to get more than the eight basic terminal colours" — not as modal qualifiers on the claim.
- Deflect out-of-scope questions to the reader explicitly: "this is something to research yourself".
- Back claims with inline links to primary documentation; every project post links its GitHub repo.
- Never introduce jargon without rule 2 or 3 applying to it.
