# SPDX-License-Identifier: MIT
# Seed table for ch-ai-workbench.claude-code.judge.dimensions: the
# peer-programmer style's rules phrased as yes/no questions for a
# System One decision model.  The model reads the finished message
# (code blocks replaced by a marker) and answers each question with
# the probability that its `true` criterion holds.  `rule` is the
# reminder the model writing the message gets back when the judge
# pushes back or reports.  Bans on a word or a character (the
# possessive handoff, "load-bearing", the em-dash, ...) are left to the
# regex table, which finds them exactly; a run of elephant-1 over
# recent sessions found it answering such questions from the tone of
# the text rather than the presence of the word.
let
  exempt = "Quoted text, text inside backticks, code, and the names of things do not count.";
in
{
  # After the user corrects the assistant in the chat, it tends to
  # write the fix's comments and docs as a correction to itself: they
  # argue the difference from what the code no longer does, or from
  # what was considered and not done ("`packages` is the project's own
  # scope, and nothing else publishes there"; "`nix.package` is not
  # set here").  They make sense only beside the chat or the old code.
  # The judge sees the edit with its replaced text and the user's
  # latest messages, so it can recognize the echo of a correction.
  # The question is asked of writes to prose and code files and of
  # commit messages and pull request texts; a reply to the person who
  # made the correction may properly discuss the difference.  A commit
  # or pull request may say what the change removes from the code
  # before it, but not rebut what existed only in the chat or in a
  # draft that never landed.
  arguing-with-ghosts = {
    instructions = "Is the new text written as a correction to its author's own earlier version instead of for a new reader who sees only the result? Look for comments, docs, or tests that argue a difference from something the code no longer does or that was chosen not to be done: saying what is not set, not published, not used, or not done anymore, or rebutting an approach that appears only in the replaced text or in the user's messages. A new reader would not have thought of that approach and does not need it ruled out.";
    criteria.true = "A comment, doc sentence, or test contrasts the result with a removed or rejected alternative that only someone who saw the old code or the conversation would know about, for example a comment echoing what the user's message corrected, or a test asserting that a mistake from an earlier draft stays absent.";
    criteria.false = "Every sentence would be written by someone who never saw the old version or the conversation: it says what the code or design is, what it does, and where things are, and none answers the replaced text or the user's messages. A commit message or pull request text may say what the change removes or replaces relative to the code before it.";
    rule = "do not argue with ghosts: write for a new reader of the code, saying what it is, what it does, and where things are; a sentence that only makes sense to someone who saw the removed, corrected, or rejected version goes, and usually belongs nowhere else either, a commit message or PR body carrying it only when a reviewer needs it to judge the change";
    targets = [
      "prose"
      "code"
      "message"
    ];
  };
  # The Stop hook judges a whole turn: the messages written between
  # tool calls, each headed [earlier message of this turn], then the
  # message headed [final message].  A reader may see only the last
  # one, so it has to carry what the turn found, changed, decided, and
  # left to do.
  final-message-recap = {
    instructions = "The text is one turn of an assistant's work: messages written between tool calls, each headed [earlier message of this turn], then the message headed [final message]. Does the final message leave out key context from the turn that a reader who sees only the final message would need: a finding, a change made, a decision, a failure or a skipped step, or the next action? When the text holds only a final message, the answer is no.";
    criteria.true = "Something the reader needs to understand or act on the outcome appears only in an earlier message, or the final message relies on an earlier message to make sense.";
    criteria.false = "A reader who sees only the final message knows what was found, what changed, what failed or was skipped, and what happens next; the earlier messages add only progress narration.";
    rule = "close with a recap a reader who sees only the last message can act on: what was found, what changed, what failed or was skipped, and what happens next";
    targets = [ "reply" ];
  };
  # Numbers reported for their own sake: tallies of edits, lines,
  # files, sections, checks, or attempts, where the reader needed to
  # know what changed or what was found.  A pattern has no handle on
  # this, since the same number is the finding in one sentence and
  # noise in the next.
  count-obsession = {
    instructions = "Does the text report counts that tell the reader nothing they need: how many edits, lines, files, tests, commits, sections, steps, or attempts there were, the size of a diff, or a tally of what was checked, in place of saying what changed, what was found, or what it means? A number is fine when it is itself the finding or the reader needs it to act, such as how many tests fail, a measurement the question asked for, or a version.";
    criteria.true = "At least one count is reported for its own sake, a tally of the work, its size, or its parts, where saying what it is or what it means would serve the reader.";
    criteria.false = "Every number answers the reader's question or is needed to act on it, or the text has no numbers.";
    rule = "report what changed and what it means, not tallies of the work (edits, lines, files, sections, checks); give a number only when the number is the finding";
  };
  # Clipped verdicts delivered as a sentence of their own for effect.
  # The line between this and fragments is whether the clipped text
  # carries a fact: a pronouncement grades or punctuates and carries
  # none, so the fix is to drop it or say the fact it grades; a fragment
  # carries facts in compressed form, so the fix is to write the
  # sentence out.
  staccato-pronouncements = {
    instructions = "Does the text make staccato pronouncements: short lines or sentences, set off on their own for effect, that grade, approve, announce, or punctuate and carry no fact about the subject, such as \"Fair.\", \"Recorded.\", \"Confirmed at the source.\", \"Decisive and favorable:\", or \"That settles it.\"? A clipped sentence that carries facts (\"Build green, pushed.\") is a different problem and does not count here, and neither does a plain one-word answer to a yes/no question.";
    criteria.true = "At least one short line or sentence carries no fact about the subject and only grades, approves, announces, or punctuates.";
    criteria.false = "Every short line carries a fact about the subject, or answers a yes/no question.";
    rule = "no staccato pronouncements; drop the clipped verdict, or say in a full sentence the fact it grades";
  };
  # Phrases that tell the reader a point matters or is interesting
  # instead of showing why.
  rhetorical-hooks = {
    instructions = "Does the text use rhetorical hooks, phrases that tell the reader something is important, interesting, or surprising instead of showing why, such as \"and it matters\", \"here's the thing\", \"that's the key part\", \"the interesting bit is\", \"this is where it gets subtle\", or \"the short version\"?";
    criteria.true = "A phrase announces the weight or interest of a point rather than stating the point or its consequence.";
    criteria.false = "Points are stated with their consequences, and no phrase only advertises them.";
    rule = "no rhetorical hooks (\"and it matters\", \"here's the thing\"); state the point and what follows from it";
  };
  selling = {
    instructions = "Does the text sell instead of describing: \"one X for all Y\" framing, claims that a problem vanishes or is solved for good, or grand or marketing language? ${exempt}";
    criteria.true = "The text promotes the work instead of saying what the mechanism does and what happens without it.";
    criteria.false = "The text describes the mechanism and its limits plainly.";
    rule = "do not sell; say what the mechanism is, what it does, and what happens without it";
  };
  # Grading the reader's point or the result before the substance.
  grading-the-point = {
    instructions = "Does the text grade the reader's point, a suggestion, or a result before or instead of answering, such as \"Fair.\", \"Agreed, and it simplifies more than it costs.\", \"Good catch.\", \"Some of that worry is earned.\", or \"Decisive and favorable:\"? ${exempt}";
    criteria.true = "A sentence or clause grades, approves, or weighs the reader's point or the result instead of saying what follows from it.";
    criteria.false = "The text answers directly, and any agreement is carried by what it goes on to say.";
    rule = "do not grade the point or the result; answer it, and let what follows show whether it holds";
  };
  # The story of the assistant's own earlier mistake, told to the
  # reader instead of the corrected content.
  self-correction-narration = {
    instructions = "Does the text narrate the author's own earlier mistake or framing, such as \"My earlier framing was muddled.\", \"I had it framed too broadly.\", \"You are right, and I should have said so when I presented it.\", or \"Neither is quite what I meant.\", instead of simply giving the corrected content?";
    criteria.true = "A sentence tells the story of the author's earlier error, framing, or omission where stating the corrected content would serve the reader.";
    criteria.false = "Corrections are given as the corrected content, and a mistake is mentioned only where the reader needs to know that something they relied on was wrong.";
    rule = "give the corrected content, not the story of the earlier mistake; say only what the reader relied on that was wrong";
  };
  # More than a reader can take in at one sitting.
  too-much-at-once = {
    instructions = "Is the message more than a reader can take in at one sitting: more points, sections, options, caveats, or detail than the reader needs right now, so that what they need to know or do is buried or would be missed? Length alone does not count when every part is needed now.";
    criteria.true = "Parts of the message could be cut or left for later without losing what the reader needs now, and the amount makes the important part hard to find.";
    criteria.false = "The reader can take the message in at once, or every part of it is needed now.";
    rule = "say less at once: lead with what the reader needs now, cut what they do not, and leave detail for when it is asked for";
    targets = [
      "reply"
      "progress"
      "message"
    ];
  };
  fragments = {
    instructions = "Does the prose carry its facts in elliptical fragments instead of full sentences: dropped subjects, verbs, or articles (\"Build green, pushed, PR open\"), colon-fragment parallelism (\"What it covers: X. What it doesn't: Y.\"), or arrows and slashes standing in for a sentence? Only compressed text that states facts counts. A short line that carries no fact and only grades or punctuates (\"Fair.\", \"Recorded.\") is a different problem and does not count here, and neither do headings, table cells, short labels in a list, or code.";
    criteria.true = "At least one passage that states facts is written as fragments the reader has to reconstruct into sentences.";
    criteria.false = "Every passage that states facts is written in full sentences with a subject and a verb.";
    rule = "write full declarative sentences with a subject and a verb; no colon-fragment parallelism, dropped words, or arrow shorthand";
  };
  process-narration = {
    instructions = "Does the text narrate how the work was done (\"I grepped for\", \"my earlier attempt\", \"after looking around\") where reporting what was found would do?";
    criteria.true = "The text tells the story of the search instead of reporting files, lines, commands, outputs, and observed behavior.";
    criteria.false = "The text reports findings in the reader's frame, or the process is itself what was asked about.";
    rule = "report what you saw (files, lines, commands, outputs), not how you found it";
  };
  undefined-terms = {
    instructions = "Does the text use an abbreviation it made up, or a shorthand coined during the work (such as \"the read-back site\" or \"drv-shaped\"), as if the reader already knew it, without defining it at first use?";
    criteria.true = "A coined term or an invented abbreviation appears without a definition.";
    criteria.false = "Every term is standard, defined at first use, or a name from the code.";
    rule = "define each concept at first use and do not use shorthand coined during the session as shared vocabulary";
    # A coinage can only be judged against what the reader has seen,
    # which the message alone does not show; report it, do not block.
    pushBack = false;
  };
}
