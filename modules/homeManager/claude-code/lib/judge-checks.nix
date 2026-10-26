# SPDX-License-Identifier: MIT
# Seed questions for the judge's per-candidate checks: the candidates
# come from claude-coinage-check and claude-reference-check, and the
# judge answers these questions about one candidate at a time, on a
# state that holds the candidate, its sentence, and what the reader saw.
{
  coinage = {
    instructions = "How much does a programmer who did not follow the conversation have to guess to know what the phrase named in the state refers to?";
    levels = [
      "Nothing: an ordinary word, a standard technical term, or a reference to something just named."
      "Little: a name for something from this work whose words say what it is (\"the edit hook\", \"the stored verdict\")."
      "Everything: a name for something from this work built from a generic word or a metaphor (\"the judge\", \"the ladder\", \"the latch\")."
    ];
  };
  references = {
    resolvable = {
      type = "noul";
      instructions = "The reader is the person who typed user_messages. They saw the assistant's replies and their own messages, but never saw tool output, file edits the assistant made, other Claude sessions or subagents. reader_saw holds everything they were shown that mentions the candidate (or 'nothing'). Reading the sentence, can they tell what the candidate refers to, either from this message itself or from reader_saw?";
      criteria.true = "The reader can tell what it refers to: the message defines or describes it, reader_saw shows it, or it is common knowledge for a programmer.";
      criteria.false = "The reader cannot tell what it refers to: it points at something they were not shown and the message does not explain it.";
    };
    presupposed = {
      type = "noul";
      instructions = "Does the sentence use the candidate as if the reader already knows which thing it is (a 'the X', 'its X' or 'their X' pointing back to something), rather than introducing it, defining it, or handing it over as a command, path, citation or new name to use?";
      criteria.true = "It is used as already known, pointing back at a specific thing.";
      criteria.false = "It is introduced, defined, or handed over for the reader to use.";
    };
  };
}
