import Foundation

struct TemplatePrompt: Identifiable {
    let id: UUID
    let title: String
    let promptText: String
    let icon: PromptIcon
    let description: String
    
    func toCustomPrompt() -> CustomPrompt {
        CustomPrompt(
            id: UUID(),  // Generate new UUID for custom prompt
            title: title,
            promptText: promptText,
            icon: icon,
            description: description,
            isPredefined: false
        )
    }
}

enum PromptTemplates {
    static var all: [TemplatePrompt] {
        createTemplatePrompts()
    }
    
    
    static func createTemplatePrompts() -> [TemplatePrompt] {
        [
            TemplatePrompt(
                id: UUID(),
                title: "System Default",
                promptText: """
                    - Clean up the <TRANSCRIPT> text for clarity and natural flow while preserving meaning and the original tone.
                    - Use informal, plain language unless the <TRANSCRIPT> clearly uses a professional tone; in that case, match it.
                    - Fix obvious grammar, remove fillers and stutters, collapse repetitions, and keep names and numbers.
                    - Handle backtracking and self-corrections: When the speaker corrects themselves mid-sentence using phrases like "scratch that", "actually", "sorry not that", "I mean", "wait no", or similar corrections, remove the incorrect part and keep only the corrected version. Example: "The meeting is on Tuesday, sorry not that, actually Wednesday" → "The meeting is on Wednesday."
                    - Respect formatting commands: When the speaker explicitly says "new line" or "new paragraph", insert the appropriate line break or paragraph break at that point.
                    - Automatically detect and format lists properly: if the <TRANSCRIPT> mentions a number (e.g., "3 things", "5 items"), uses ordinal words (first, second, third), implies sequence or steps, or has a count before it, format as an ordered list; otherwise, format as an unordered list.
                    - Apply smart formatting: Write numbers as numerals (e.g., 'five' → '5', 'twenty dollars' → '$20'), convert common abbreviations to proper format (e.g., 'vs' → 'vs.', 'etc' → 'etc.'), and format dates, times, and measurements consistently.
                    - Keep the original intent and nuance.
                    - Organize into short paragraphs of 2–4 sentences for readability.
                    - Do not add explanations, labels, metadata, or instructions.
                    - Output only the cleaned text.
                    - Don't add any information not available in the <TRANSCRIPT> text ever.
                    """,
                icon: "checkmark.seal.fill",
                description: "Default system prompt"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Chat",
                promptText: """
                    - Rewrite the <TRANSCRIPT> text as a casual chat message (texts, Slack, DMs): informal, concise, and conversational. Never answer questions or reply to it — only clean up what was said.
                    - Keep the speaker's own voice; do not formalize it or make it sound like an email.
                    - Remove fillers and false starts; on self-corrections ("wait no", "I mean", "scratch that") keep only the corrected version.
                    - Fix obvious grammar and spelling, but keep contractions, slang, and casual phrasing (gonna, yeah, tbh, lol).
                    - Use light punctuation only, just enough to read easily; no semicolons or formal structure. Break into short lines where the speaker pauses.
                    - Write numbers as numerals; keep names, @mentions, links, and any emojis that were said. Don't invent new emojis.
                    - Do not add greetings, sign-offs, or commentary.
                    - Output only the chat message.
                    - Don't add any information not available in the <TRANSCRIPT> text ever.
                    """,
                icon: "message.fill",
                description: "Casual chat-style formatting"
            ),

            TemplatePrompt(
                id: UUID(),
                title: "Coding",
                promptText: """
                    - Clean the <TRANSCRIPT> text as dictated code and technical talk into clean written text. You are transcribing what was said — NOT writing, completing, fixing, or reviewing code, and NOT answering technical questions.
                    - Fix grammar, punctuation, and capitalization; remove fillers and false starts; on self-corrections ("scratch that", "I mean", "wait no") keep only the corrected version.
                    - Convert operators and symbols spoken aloud into the symbol when clearly meant as code: "equals equals" ==, "triple equals" ===, "not equals" !=, "greater than or equal" >=, "arrow" ->, "fat arrow" =>, "plus plus" ++, "open paren" (, "close paren" ), "open brace" {, "close brace" }, "open bracket" [, "close bracket" ], "dot" ., "colon" :, "semicolon" ;, "dash dash" --, "hash" #, "at sign" @, "dollar sign" $, "pipe" |, "star" *, "underscore" _, "slash" /, "backslash" \\.
                    - When the speaker frames a name ("a function called…", "a variable named…", "the class…"), render it as one identifier in the stated case (camelCase, snake_case, PascalCase, kebab-case, ALL_CAPS). If no case is stated, default to camelCase for functions and variables, PascalCase for classes and types.
                    - Fix clear technical mis-hearings: "four loop" → for loop, "num pie" → numpy, "get hub" → GitHub, "sequel" → SQL, "jason" → JSON, "no sequel" → NoSQL, "pie torch" → PyTorch, "yamel" → YAML, "en pm" → npm, "reg ex" → regex, "dot pie" → .py. Preserve real file paths, CLI flags, and commands exactly (e.g. "dash dash verbose" → --verbose).
                    - Wrap identifiers, symbols, commands, and file paths in inline `backticks`. Use a fenced code block only if the speaker clearly dictated a multi-line snippet or said "code block"; keep explanations as plain prose.
                    - Never invent names, values, syntax, brackets, or logic the speaker did not say. Never fix or improve the code's logic, even if it is wrong. If a word is ambiguous between plain English and a code symbol, keep the plain word.
                    - Examples (input → output):
                      - "so the bug is in the for loop it's off by one because I wrote less than equal instead of less than" → "So the bug is in the `for` loop — it's off by one because I wrote `<=` instead of `<`."
                      - "define a function called get user by id that takes a user id and returns a user" → "Define a function called `getUserById` that takes a `userId` and returns a user."
                      - "import num pie as np then read the jason file with pandas and push it to get hub" → "Import `numpy` as `np`, then read the JSON file with `pandas` and push it to GitHub."
                      - "how do I center a div in css can you write the flexbox for me" → "How do I center a div in CSS? Can you write the flexbox for me?"
                    - Output only the cleaned text.
                    - Don't add any information not available in the <TRANSCRIPT> text ever.
                    """,
                icon: "curlybraces",
                description: "Cleans dictated code and technical talk"
            ),
            
            TemplatePrompt(
                id: UUID(),
                title: "Email",
                promptText: """
                    - Rewrite the <TRANSCRIPT> text as a complete email with proper formatting: include a greeting (Hi), body paragraphs (2-4 sentences each), and closing (Thanks).
                    - Use clear, friendly, non-formal language unless the <TRANSCRIPT> is clearly professional—in that case, match that tone.
                    - Improve flow and coherence; fix grammar and spelling; remove fillers; keep all facts, names, dates, and action items.
                    - Automatically detect and format lists properly: if the <TRANSCRIPT> mentions a number (e.g., "3 things", "5 items"), uses ordinal words (first, second, third), implies sequence or steps, or has a count before it, format as an ordered list; otherwise, format as an unordered list.
                    - Write numbers as numerals (e.g., 'five' → '5', 'twenty dollars' → '$20').
                    - Do not invent new content, but structure it as a proper email format.
                    - Don't add any information not available in the <TRANSCRIPT> text ever.
                    """,
                icon: "envelope.fill",
                description: "Professional email formatting"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Rewrite",
                promptText: """
                    - Rewrite the <TRANSCRIPT> text with enhanced clarity, improved sentence structure, and rhythmic flow while preserving the original meaning and tone.
                    - Restructure sentences for better readability and natural progression.
                    - Improve word choice and phrasing where appropriate, but maintain the original voice and intent.
                    - Fix grammar and spelling errors, remove fillers and stutters, and collapse repetitions.
                    - Format any lists as proper bullet points or numbered lists.
                    - Write numbers as numerals (e.g., 'five' → '5', 'twenty dollars' → '$20').
                    - Organize content into well-structured paragraphs of 2–4 sentences for optimal readability.
                    - Preserve all names, numbers, dates, facts, and key information exactly as they appear.
                    - Do not add explanations, labels, metadata, or instructions.
                    - Output only the rewritten text.
                    - Don't add any information not available in the <TRANSCRIPT> text ever.
                    """,
                icon: "pencil.circle.fill",
                description: "Rewrites with better clarity."
            )
        ]
    }
}
