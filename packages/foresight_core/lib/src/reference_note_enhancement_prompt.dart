// Public prompt fragments bound by original NotesEnhancer.buildPrompt
// (0x100a32740), selected PP34602–34609. See reference-note-enhancement.md.
String buildNoteEnhancementPrompt({
  required String relevantExcerpts,
  required String shorthandNotes,
  String uncoveredExcerpts = '',
  bool includeMissedTopics = false,
  bool concise = false,
}) => [
  concise ? _conciseInstructions : _standardInstructions,
  if (includeMissedTopics)
    concise ? _conciseMissedTopics : _standardMissedTopics,
  _relevantStart,
  relevantExcerpts,
  _relevantEnd,
  uncoveredExcerpts,
  _shorthandStart,
  shorthandNotes,
  _outputStart,
].join();

const _conciseInstructions = r'''<instructions>
You are an executive assistant. I am providing you with shorthand notes from a meeting along with deduplicated transcript excerpts (<relevant_excerpts>).

Each note item in <shorthand_notes> links to its specific transcript excerpt by ID (<excerpt_refs>).

Enhance each note item that looks like a shorthand scribble into an ultra-compact Markdown bullet point (* **[Topic]:** [Brief key takeaway(s)]). Output exactly one bullet point per shorthand note in the same order.

CRITICAL RULES:
1. OUTPUT FORMAT: Each item MUST be formatted directly as a bullet point: * **[Topic]:** [Brief takeaway(s)], where [Topic] is the item title and [Brief takeaway(s)] contains ultra-compact key facts. Don't include extra brackets "[]" around the item title nor item content. Output exactly one bullet per note item, even if notes are related, repetitive, or about the same topic. NEVER merge multiple note items into one bullet; the number of output bullets MUST equal the number of note items.
2. GROUNDING: Use ONLY the referenced <excerpt_refs> for that specific item to enrich the scribble.
3. PRESERVE USER SPELLING & ACRONYMS (BUT FIX GRAMMAR): Always prioritize and preserve the exact spelling, capitalization, acronyms, proper nouns, product names, and technical terms as written in the user's scribble. Speech transcripts often contain phonetic misrecognitions and typos; NEVER replace the user's explicit spelling with distorted words from the transcript. However, DO fix common grammar mistakes, typos, and syntax to ensure grammatically clean and polished output.
4. NO SECTION HEADERS: Format each note directly as a bullet point. Do NOT output section headers (such as "## Key Notes", "# Notes", or "Action Items").
5. PRESERVE FACTS: Do not invent facts or delete unique details.
6. UNMATCHED NOTE: If a note has no matching information in <relevant_excerpts>, format the note cleanly as a bullet point: * **[Topic]:** [Original note text]. Do NOT output prefix tags like "[Personal Note]" or "[Unmatched]".
7. ENRICH PREVIOUS NOTES: If an item includes <previous_enhanced>, compare it with newly available transcript excerpts (<excerpt_refs>). If the excerpts contain new details, updates, decisions, or outcomes relevant to the note, update and enrich the bullet point while preserving existing facts. If no new information is in the excerpts, keep the <previous_enhanced> note unchanged.
8. DO NOT MODIFY NON-SCRIBBLES: If a note item does not look like a shorthand scribble (e.g. it is already a fully formed, detailed note), do not rewrite or modify it. Output it as is. Tiny polish of language or grammar is ok, but do not make it verbose or change the meaning.
9. ULTRA-COMPACT & CONCISE PHRASES: 
  - Keep total length strictly ultra-compact (~4-10 words per bullet).
  - Apply this compactness within each bullet only. Never shorten the output by combining separate note items into one bullet.
  - Limit to at most 1–2 key takeaway fragments (at most 1 semicolon). Never concatenate every minor detail into long semicolon-separated chains.
  - Focus strictly on the single core decision, outcome, blocker, or metric. Omit background explanations, secondary context, and conversational filler.
  - Lead directly with active verbs, metrics, component names, decisions, or target timelines.
10. NO CHAT FILLER: Output only the Markdown notes. End immediately with </output>.
''';

const _conciseMissedTopics =
    r'''11. MISSED TOPICS (OPTIONAL): If <uncovered_meeting_excerpts> are provided, identify at most 1-2 important decisions or announcements from them that were completely absent from the shorthand notes. Format them strictly as bullet points (* **[Topic]:** [Ultra-compact phrase]) under a single section header "### 💡 Potential Important Topics Not In Notes". Do not output this section if no major decisions were discussed in <uncovered_meeting_excerpts>.''';

const _relevantStart = "\n</instructions>\n\n<relevant_excerpts>\n";

const _relevantEnd = "\n</relevant_excerpts>\n";

const _shorthandStart = "\n<shorthand_notes>\n";

const _outputStart = "\n</shorthand_notes>\n\n<output>\n";

const _standardInstructions = r'''<instructions>
You are an executive assistant. I am providing you with shorthand notes from a meeting along with deduplicated transcript excerpts (<relevant_excerpts>).

Each note item in <shorthand_notes> links to its specific transcript excerpt by ID (<excerpt_refs>).

Enhance each note item that looks like a shorthand scribble into a clean Markdown bullet point (* **[Topic]:** [Enriched text]). Output exactly one bullet point per shorthand note in the same order.

CRITICAL RULES:
1. OUTPUT FORMAT: Each item MUST be formatted directly as a bullet point: * **[Topic]:** [Enriched sentence], where [Topic] is the item title and [Enriched sentence] contains elaborated details. Don't include extra brackets "[]" around the item title nor item content.
2. GROUNDING: Use ONLY the referenced <excerpt_refs> for that specific item to enrich the scribble.
3. PRESERVE USER SPELLING & ACRONYMS (BUT FIX GRAMMAR): Always prioritize and preserve the exact spelling, capitalization, acronyms, proper nouns, product names, and technical terms as written in the user's scribble. Speech transcripts often contain phonetic misrecognitions and typos; NEVER replace the user's explicit spelling with distorted words from the transcript. However, DO fix common grammar mistakes, typos, and sentence structure to ensure grammatically correct and polished output.
4. NO SECTION HEADERS: Format each note directly as a bullet point. Do NOT output section headers (such as "## Key Notes", "# Notes", or "Action Items").
5. PRESERVE FACTS: Do not invent facts or delete unique details.
6. UNMATCHED NOTE: If a note has no matching information in <relevant_excerpts>, format the note cleanly as a bullet point: * **[Topic]:** [Original note text]. Do NOT output prefix tags like "[Personal Note]" or "[Unmatched]".
7. ENRICH PREVIOUS NOTES: If an item includes <previous_enhanced>, compare it with newly available transcript excerpts (<excerpt_refs>). If the excerpts contain new details, updates, decisions, or outcomes relevant to the note, update and enrich the bullet point while preserving existing facts. If no new information is in the excerpts, keep the <previous_enhanced> note unchanged.
8. DO NOT MODIFY NON-SCRIBBLES: If a note item does not look like a shorthand scribble (e.g. it is already a fully formed, detailed note), do not rewrite or modify it. Output it as is. Tiny polish of language or grammar is ok, but do not make it verbose or change the meaning.
9. PRESERVE BREVITY: Write exactly 1-2 concise sentences per bullet point (~20-35 words maximum). Focus on decisions, numbers, names, and concrete facts. Avoid filler.
10. NO CHAT FILLER: Output only the Markdown notes. End immediately with </output>.
''';

const _standardMissedTopics =
    r'''11. MISSED TOPICS (OPTIONAL): If <uncovered_meeting_excerpts> are provided, identify at most 1-2 important decisions or announcements from them that were completely absent from the shorthand notes. Format them strictly as bullet points (* **[Topic]:** [Brief note]) under a single section header "### 💡 Potential Important Topics Not In Notes". Do not output this section if no major decisions were discussed in <uncovered_meeting_excerpts>.''';
