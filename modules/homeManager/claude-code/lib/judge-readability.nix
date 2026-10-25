# SPDX-License-Identifier: MIT
# Seed score dimensions for ch-ai-workbench.claude-code.judge.dimensions:
# who could know what a finished reply is talking about.  Every
# dimension uses the same ladder of background a reader needs, from an
# average developer up to someone who took part in the chat that
# produced the reply, and each asks how far up the ladder one cause (the
# length, the density, the references, ...) puts the reply; the first
# asks about the reply in total.  So a long reply that an average
# developer can follow scores low on length.  The judge returns a
# probability for each level.  Scores never push back: the context hook
# hands every one to the model with the next prompt, as the expected
# position on the ladder and the most likely level, beside `rule`, the
# peer-programmer style's aim for that cause.
let
  levels = [
    "an average developer can follow it"
    "it needs a developer familiar with the ecosystem: the languages, tools, and frameworks involved"
    "it needs a developer familiar with this codebase"
    "it leans on references that seem to come from the chat or task that produced it, which only someone who took part would know"
  ];
  effort = cause: rule: {
    type = "score";
    instructions = "What does a developer need to know already to know what the message is talking about, ${cause}?";
    inherit levels rule;
    targets = [
      "reply"
      "progress"
    ];
  };
in
{
  readability = effort "taking the message as a whole" "write for a programmer who has not seen the work or most of the codebase";

  length = effort "given how long it is: points the developer has to hold while reading on, or has to dig out from among other points" "keep messages short, but cut whole points the reader does not need rather than the words a point needs";

  density = effort "given how much each sentence carries: facts packed together that only a reader who already knows them can unpack quickly" "one fact per sentence, with the words it needs to be understood on first reading";

  complexity = effort "given how its sentences and reasoning are built: long sentences, nested clauses, reasoning chained across steps the message does not spell out" "plain declarative sentences with a subject and a verb";

  nuance = effort "given the qualifications, caveats, exceptions, and fine distinctions the developer has to place to find the main point" "lead with the point, and state each caveat once, next to what it qualifies";

  references = effort "given the things outside the message it points at: files, options, commands, pull requests, earlier messages, earlier decisions" "give each file, option, module, or command its path or name and a few words on what it does at first mention";

  jargon = effort "given its jargon that is not standard for a working programmer in this domain: terms coined during the work, project-internal names used without saying what they are, unusual words where plain ones exist (standard technical terms of the domain count as ecosystem knowledge)" "define each project-specific concept at first use; no shorthand coined during the session";

  # Off the ladder: how much the reply itself packs into each sentence,
  # whoever reads it.  Both ends are a problem, filler at one and
  # unbroken fact after fact at the other.
  information-density = {
    type = "score";
    instructions = "How much does each sentence of the message carry, whoever reads it?";
    levels = [
      "sparse: filler, repetition, or points restated"
      "even: about one point per sentence"
      "dense: several facts per sentence"
      "packed: nearly every clause carries a fact the reader has to stop and take in"
    ];
    rule = "one point per sentence, with the words it needs; cut filler and restatement";
    targets = [
      "reply"
      "progress"
    ];
  };

  generic-concept-words = effort "given generic nouns used as if they named a specific concept without saying what it is, such as \"the fold\", \"the gate\", \"the surface\", \"the shape\", or \"the path\"" "name the actual thing (the function, the file, the check) instead of a generic noun that stands for it";
}
