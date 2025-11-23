defmodule Normalizer do
  def run do
    files = Path.wildcard("lib/**/*.{ex,heex}")

    Enum.each(files, fn file ->
      content = File.read!(file)
      new_content = normalize(content)

      if content != new_content do
        IO.puts("Normalizing #{file}")
        File.write!(file, new_content)
      end
    end)
  end

  def normalize(content) do
    # We process the file by finding matches and replacing them.
    # Because replacements change indices, we can process from the end or just loop.
    # A simple way is to split by lines and process, but multi-line is the challenge.
    # Let's use a regex to find the start, then parse forward.

    regex = ~r/^\s*(attr|slot|embed_templates)(?:\s+)(:[a-zA-Z0-9_]+|"[^"]+")/m

    do_normalize(content, regex)
  end

  defp do_normalize(content, regex) do
    case Regex.run(regex, content, return: :index) do
      nil ->
        content

      [{start, len}, {func_start, func_len}, {arg_start, _arg_len}] ->
        # Check if already has paren
        # The regex matches `attr :foo` or `attr "foo"` (for embed).
        # We need to check if there is a paren between func and arg.
        # Our regex expects whitespace `\s+` between them.
        # If it was `attr(:foo`, the regex `\s+` would fail or we can check.

        # Actually, let's look at the text between func end and arg start.
        # func_end = func_start + func_len
        # text_between = binary_part(content, func_end, arg_start - func_end)
        # if String.contains?(text_between, "("), do: skip

        # But our regex `(?:\s+)` enforces whitespace, so it won't match `attr(` (unless there is space `attr (`, which is valid but rare).
        # Let's assume if it matches `\s+`, it needs normalization.

        # We need to find the end of the arguments.
        # Start scanning from `start + len`.
        # We are looking for the end of the expression.

        match_end = start + len
        rest_of_file = binary_part(content, match_end, byte_size(content) - match_end)

        {args_end_offset, has_do_block} = find_args_end(rest_of_file)

        total_args_end = match_end + args_end_offset

        # Construct new string
        # prefix: content up to func_end
        # insert "("
        # middle: content from arg_start to total_args_end
        # insert ")"
        # suffix: content from total_args_end

        prefix = binary_part(content, 0, func_start + func_len)
        middle = binary_part(content, arg_start, total_args_end - arg_start)
        suffix = binary_part(content, total_args_end, byte_size(content) - total_args_end)

        new_content = prefix <> "(" <> middle <> ")" <> suffix

        # Recurse on the NEW content.
        # To avoid infinite loop on the same match, we must ensure we don't match the one we just fixed.
        # The fixed one looks like `attr(:foo`.
        # The regex looks for `attr\s+:foo`.
        # `attr(` does NOT match `attr\s+`.
        # So it should be safe.

        do_normalize(new_content, regex)
    end
  end

  defp find_args_end(text) do
    # Scan char by char.
    # Track nesting: (), [], {}, <<>>, "" (strings), '' (char lists)
    # Stop when nesting is 0 AND:
    # - We hit ` do` (space do) -> return offset before `do`.
    # - We hit newline AND the next line does not look like a continuation.

    chars = String.to_charlist(text)
    scan(chars, 0, [], false)
  end

  # scan(chars, index, stack, in_string)
  # stack holds closing chars expected: ) ] } >>

  # End of file
  defp scan([], idx, _, _), do: {idx, false}

  # String handling
  defp scan([?" | rest], idx, stack, false), do: scan(rest, idx + 1, [?" | stack], true)
  defp scan([?" | rest], idx, [?" | stack], true), do: scan(rest, idx + 1, stack, false)
  # Skip chars in string
  defp scan([_ | rest], idx, stack, true), do: scan(rest, idx + 1, stack, true)

  # Nesting
  defp scan([?( | rest], idx, stack, false), do: scan(rest, idx + 1, [?) | stack], false)
  defp scan([?) | rest], idx, [?) | stack], false), do: scan(rest, idx + 1, stack, false)

  defp scan([?[ | rest], idx, stack, false), do: scan(rest, idx + 1, [?] | stack], false)
  defp scan([?] | rest], idx, [?] | stack], false), do: scan(rest, idx + 1, stack, false)

  defp scan([?{ | rest], idx, stack, false), do: scan(rest, idx + 1, [?} | stack], false)
  defp scan([?} | rest], idx, [?} | stack], false), do: scan(rest, idx + 1, stack, false)

  # Check for " do" or " do:" (do: is a keyword arg, not a block)
  # If stack is empty, check for delimiters
  # " do " -> block
  defp scan([?\s, ?d, ?o, ?\s | _] = list, idx, [], false), do: {idx, true}
  # " do\n" -> block
  defp scan([?\s, ?d, ?o, ?\n | _] = list, idx, [], false), do: {idx, true}

  # Newline check
  defp scan([?\n | rest], idx, [], false) do
    # Check next non-whitespace char
    case next_significant_char(rest) do
      # EOF
      nil ->
        {idx, false}

      char ->
        if is_continuation?(char) do
          scan(rest, idx + 1, [], false)
        else
          # End of args
          {idx, false}
        end
    end
  end

  # Comma at end of line (before newline)
  # We need to track if the PREVIOUS char was a comma?
  # Or just keep scanning.
  # If we are at nesting 0, and we see a comma, we continue.
  defp scan([?, | rest], idx, [], false), do: scan(rest, idx + 1, [], false)

  defp scan([_ | rest], idx, stack, in_string), do: scan(rest, idx + 1, stack, in_string)

  defp next_significant_char([]), do: nil
  defp next_significant_char([?\s | rest]), do: next_significant_char(rest)
  defp next_significant_char([?\t | rest]), do: next_significant_char(rest)
  defp next_significant_char([?\r | rest]), do: next_significant_char(rest)
  # Comment starts line? Treat as end? Or continuation? Usually end.
  defp next_significant_char([?# | _]), do: nil
  defp next_significant_char([char | _]), do: char

  defp is_continuation?(char) do
    # Common operators that start a line
    char in [?,, ?+, ?-, ?*, ?/, ?|, ?., ?=, ?&]
    # Also check for closing delimiters? No, stack is empty.
    # Actually, in Elixir, if a line ends without an operator, the statement ends.
    # Unless there is an open paren/bracket (handled by stack).
    # So if stack is empty, and we hit newline, we only continue if the NEXT line starts with an operator (pipe | is common).
    # But `attr` args are usually keyword lists.
    # `attr :foo, :string`
    # `  default: "bar"`
    # The comma is usually at the end of the previous line.
    # If the previous line ended with comma, we would have consumed it in `scan`.
    # Wait, my `scan` consumes char by char.
    # If I hit `\n`, I need to know if the *previous* significant char was a comma or operator.
    # This state tracking is getting complex.
  end

  # SIMPLIFIED STRATEGY for `find_args_end`:
  # Just look for ` do` block or `\n` that terminates the statement.
  # But how to know if `\n` terminates?
  # Let's rely on the fact that `attr` args are comma separated.
  # If we see a comma, we are definitely continuing.
  # If we see a newline, we look back.
  # Let's change `scan` to track `last_token`.

  # Actually, let's try a simpler heuristic:
  # Parse until we hit ` do` (block start) or `\n` followed by a line that starts with a keyword (e.g. `attr`, `slot`, `def`, `@doc`).
  # `attr` definitions are usually followed by another `attr` or `def`.
  # If we see `attr` or `slot` or `def` or `@` at the start of the next line, we are definitely done.
  # This is safer.

  defp scan_heuristic(text) do
    # ... implementation ...
  end
end

# Let's rewrite the scanner to be simpler and robust enough for this task.
# We will use a regex-based scanner for the "end".
# We want to find the position where the expression ends.
# It ends at ` do` (start of block) OR at the start of the next top-level attribute/function.
# But we must respect parens/brackets/strings.

defmodule NormalizerSimple do
  def run do
    files = Path.wildcard("lib/**/*.{ex,heex}")

    Enum.each(files, fn file ->
      content = File.read!(file)
      new_content = process(content)

      if content != new_content do
        IO.puts("Updated #{file}")
        File.write!(file, new_content)
      end
    end)
  end

  def process(content) do
    # We iterate line by line to handle the "start of next line" logic easily.
    # But we need to handle multi-line accumulation.

    lines = String.split(content, "\n")

    {new_lines, _} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, pending} ->
        # pending is {func_name, buffer_of_lines}

        if pending do
          {func, buffer} = pending
          # Check if this line terminates the pending statement.
          # It terminates if:
          # 1. It starts with `attr`, `slot`, `def`, `@`, `end`.
          # 2. AND the nesting count in buffer is 0.

          full_text = Enum.join(Enum.reverse([line | buffer]), "\n")

          if statement_ended?(full_text) do
            # Convert the buffer
            converted = convert_statement(Enum.reverse(buffer), func)
            # The current line is NOT part of the statement (it's the start of the next one).
            # So we push converted buffer to acc, and process current line as new.

            # Wait, `statement_ended?` needs to know if the *previous* text was complete.
            # This is getting complicated.

            # Let's go back to the Regex replacement with a smart lookahead.
            # We can use `Code.string_to_quoted` to verify validity?
            nil
          end

          nil
        end

        # ...
        {acc, pending}
      end)

    # Let's stick to the char scanner. It was on the right track.
    # We just need to handle the "newline" case correctly.

    regex = ~r/^\s*(attr|slot|embed_templates)(?:\s+)(:[a-zA-Z0-9_]+|"[^"]+")/m
    do_normalize(content, regex)
  end

  defp do_normalize(content, regex) do
    case Regex.run(regex, content, return: :index) do
      nil ->
        content

      [{start, len}, {func_start, func_len}, {arg_start, _arg_len}] ->
        match_end = start + len
        rest = binary_part(content, match_end, byte_size(content) - match_end)

        {offset, _} = find_end(rest)
        total_end = match_end + offset

        prefix = binary_part(content, 0, func_start + func_len)
        middle = binary_part(content, arg_start, total_end - arg_start)
        suffix = binary_part(content, total_end, byte_size(content) - total_end)

        # Trim trailing whitespace from middle to put `)` close to the last char?
        # No, `mix format` will handle spacing.

        new_content = prefix <> "(" <> middle <> ")" <> suffix
        do_normalize(new_content, regex)
    end
  end

  defp find_end(text) do
    chars = String.to_charlist(text)
    scan(chars, 0, [], false)
  end

  defp scan([], idx, _, _), do: {idx, false}

  # Strings
  defp scan([?" | t], i, [?" | s], true), do: scan(t, i + 1, s, false)
  defp scan([?" | t], i, s, false), do: scan(t, i + 1, [?" | s], true)
  defp scan([_ | t], i, s, true), do: scan(t, i + 1, s, true)

  # Parens/Brackets
  defp scan([?( | t], i, s, false), do: scan(t, i + 1, [?) | s], false)
  defp scan([?) | t], i, [?) | s], false), do: scan(t, i + 1, s, false)
  defp scan([?[ | t], i, s, false), do: scan(t, i + 1, [?] | s], false)
  defp scan([?] | t], i, [?] | s], false), do: scan(t, i + 1, s, false)
  defp scan([?{ | t], i, s, false), do: scan(t, i + 1, [?} | s], false)
  defp scan([?} | t], i, [?} | s], false), do: scan(t, i + 1, s, false)

  # Block start ` do` -> End of args
  defp scan([?\s, ?d, ?o, ?\s | _], i, [], false), do: {i, true}
  defp scan([?\s, ?d, ?o, ?\n | _], i, [], false), do: {i, true}
  # ` do` at end of string?
  defp scan([?\s, ?d, ?o], i, [], false), do: {i, true}

  # Newline check
  defp scan([?\n | t], i, [], false) do
    # If stack is empty, newline MIGHT end the statement.
    # Check next significant char.
    case next_sig(t) do
      # EOF ends it
      nil ->
        {i, false}

      char ->
        if char in [?,, ?+, ?-, ?*, ?/, ?|, ?., ?=, ?&] do
          # Continuation
          scan(t, i + 1, [], false)
        else
          # Not a continuation -> End of statement
          {i, false}
        end
    end
  end

  defp scan([_ | t], i, s, false), do: scan(t, i + 1, s, false)

  defp next_sig([]), do: nil
  defp next_sig([?\s | t]), do: next_sig(t)
  defp next_sig([?\t | t]), do: next_sig(t)
  defp next_sig([?\r | t]), do: next_sig(t)
  # Comment -> effectively end of line logic applies, but we treat as end of statement for safety?
  defp next_sig([?# | _]), do: nil
  defp next_sig([char | _]), do: char
end

NormalizerSimple.run()
