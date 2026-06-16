---
description: Create handoff document for transferring work to another session
---

# Create Handoff

You are tasked with writing a handoff document to hand off your work to another agent in a new session. You will create a handoff document that is thorough, but also **concise**. The goal is to compact and summarize your context without losing any of the key details of what you're working on.

## Process

### 1. Filepath

Create your file under `docs/handoffs/YYYY-MM-DD_HH-MM-SS_description.md`, where:
- `YYYY-MM-DD` is today's date
- `HH-MM-SS` is the current time, 24-hour format
- `description` is a brief kebab-case description of the work

Example: `docs/handoffs/2026-06-16_14-30-00_create-context-compaction.md`

### 2. Handoff writing

Write the document with the following YAML frontmatter and structure, filling in details from the current session (use `git log -1`, `git branch --show-current`, etc. for the git metadata):

```markdown
---
date: [Current date and time with timezone in ISO format]
git_commit: [Current commit hash]
branch: [Current branch name]
repository: [Repository name]
topic: "[Feature/Task Name] Implementation Strategy"
tags: [implementation, strategy, relevant-component-names]
status: complete
last_updated: [Current date in YYYY-MM-DD format]
type: implementation_strategy
---

# Handoff: {very concise description}

## Task(s)
{description of the task(s) you were working on, along with the status of each (completed, work in progress, planned/discussed). If working from a plan, call out which phase you are on, and reference the plan/research document(s) you started from, if applicable.}

## Critical References
{List any critical specification documents, architectural decisions, or design docs that must be followed. Include only the 2-3 most important file paths. Leave blank if none.}

## Recent changes
{Describe recent changes made to the codebase, in line:file syntax}

## Learnings
{Describe important things you learned - e.g. patterns, root causes of bugs, or other important information someone picking up your work should know. List explicit file paths where relevant.}

## Artifacts
{An exhaustive list of artifacts you produced or updated as filepaths and/or file:line references - e.g. paths to feature documents, implementation plans, etc. that should be read in order to resume your work.}

## Action Items & Next Steps
{A list of action items and next steps for the next agent to accomplish, based on your tasks and their statuses.}

## Other Notes
{Other notes, references, or useful information - e.g. where relevant sections of the codebase or documents are, or other important things you learned that don't fall into the above categories.}
```

### 3. Confirm

Once the document is written, respond to the user with:

```
Handoff created at path/to/handoff.md
```

## Additional Notes & Instructions

- **More information, not less**. This is a guideline that defines the minimum of what a handoff should be. Always feel free to include more information if necessary.
- **Be thorough and precise**. Include both top-level objectives and lower-level details as necessary.
- **Avoid excessive code snippets**. A brief snippet to describe a key change is fine, but avoid large code blocks or diffs unless necessary (e.g. pertains to an error you're debugging). Prefer `/path/to/file.ext:line` references that an agent can follow later when it's ready, e.g. `src/app/dashboard/page.tsx:12-24`.
