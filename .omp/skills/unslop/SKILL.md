---
name: unslop
description: Detect and eliminate AI residue, formulaic patterns, robotic phrasing, and unnecessary code slop from text and code. Use when prompted to "unslop", "humanize", "de-slop", "remove AI tells", "clean up AI text", or when reviewing drafts and code that sound overly synthetic, sycophantic, or bloated.
license: MIT
user-invocable: true
argument-hint: "[rewrite | cleanup | audit] [input]"
metadata:
  version: "1.0.0"
---

# Unslop: Anti-AI Residue & Style Calibration

Eliminate formulaic "AI slop" from prose, documentation, commit messages, and code. Make outputs direct, precise, grounded, and human.

## Core Anti-Slop Principles

1. **Be Direct & Concise**: Deliver the substance immediately without introductory throat-clearing or summary wrap-ups.
2. **Eliminate Stock Vocabulary**: Remove inflated, generic LLM buzzwords.
3. **Break Formulaic Rhythm**: Avoid monotonous sentence lengths, forced three-part parallelism (tricolons), and excessive em-dash stacks.
4. **Preserve Exact Meaning & Facts**: Never compromise technical accuracy, file paths, code syntax, or domain specifics.
5. **No Code Slop**: Do not write comments that narrate obvious syntax, add speculative boilerplate, or invent unnecessary abstractions.

---

## Slop Taxonomy (What to Eliminate)

### 1. Inflated AI Vocabulary
Replace or cut these overused marker words:
- *Verbs*: delve, foster, harness, streamline, revolutionize, bolster, orchestrate, showcase, elevate, transcend, navigate.
- *Nouns*: tapestry, testament, beacon, paradigm, realm, landscape, symphony, nexus, cornerstone.
- *Adjectives*: pivotal, multifaceted, paramount, transformative, comprehensive, crucial, intricate, vibrant, indelible.

### 2. Conversational & Structural Filler
- **Opening cliches**: "Certainly!", "Sure thing!", "Here is a breakdown of...", "Let's dive in.", "In today's fast-paced world...".
- **Closing fluff**: "In conclusion...", "It's important to remember...", "Let me know if you need anything else!", "Hope this helps!".
- **Hedging chains**: "It is worth noting that...", "It might arguably be said that...", "One could consider...".
- **Forced contrasts**: "It is not just X, but a fundamental Y", "More than just a tool, it is a...".

### 3. Structural Tells
- **Forced lists of three**: AI defaults to grouping adjectives and examples in sets of 3. Use 1, 2, 4, or whatever the actual data demands.
- **Em-dash overuse**: Limit em-dashes (`—`) to occasional emphatic breaks; do not string 3+ across two sentences.
- **Bullet-point inflation**: Use standard paragraphs for narrative explanation; reserve bullet points for actual lists of discrete items.

### 4. Code & Commit Slop
- **Self-narrating comments**: Remove comments like `// Increment i` or `// Return the result`.
- **Over-engineered wrappers**: Avoid wrapping simple standard library calls in one-off helper classes without architectural necessity.
- **Vague commits**: Replace `Updated files with various improvements and refactorings` with imperative, concise descriptions: `feat(mcp): add timeout configuration to immich client`.

---

## Modes

### `rewrite` (Default)
Perform a two-pass transformation:
1. **Diagnosis**: Scan the input for telltale AI markers, stock words, and pacing issues.
2. **Reconstruction**: Re-author the text in a direct, crisp voice. Keep all code blocks, variables, and factual points intact.

### `cleanup` / `audit`
Report detected patterns and suggest minimal, targeted diffs instead of a full rewrite.

---

## Integration Contract

- **Subagent / Worker tasks**: Always apply unslop filtering to documentation, summaries, commit messages, and user-facing explanations.
- **Skill Invocations**: Triggered via `/unslop <text>`, `@unslop`, or whenever the user requests humanized writing.
