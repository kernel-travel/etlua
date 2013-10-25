
import insert, concat from table

setfenv = setfenv or (fn, env) ->
  local name
  i = 1
  while true
    name = debug.getupvalue fn, i
    break if not name or name == "_ENV"
    i += 1

  if name
    debug.upvaluejoin fn, i, (-> env), 1

  fn

html_escape_entities = {
  ['&']: '&amp;'
  ['<']: '&lt;'
  ['>']: '&gt;'
  ['"']: '&quot;'
  ["'"]: '&#039;'
}

html_escape = (str) ->
  (str\gsub [=[["><'&]]=], html_escape_entities)

get_line = (str, line_num) ->
  -- todo: this returns an extra blank line at the end
  for line in str\gmatch "([^\n]*)\n?"
    return line if line_num == 1
    line_num -= 1

pos_to_line = (str, pos) ->
  line = 1
  for _ in str\sub(1, pos)\gmatch("\n")
    line += 1
  line

class Parser
  open_tag: "<%"
  close_tag: "%>"
  modifiers: "^[=-]"
  html_escape: true

  next_tag: =>
    start, stop = @str\find @open_tag, @pos, true

    -- no more tags, all done
    unless start
      @push_raw @pos, #@str
      return false

    -- add text before
    unless start == @pos
      @push_raw @pos, start - 1

    @pos = stop + 1
    modifier = if @str\match @modifiers, @pos
      with @str\sub @pos, @pos
        @pos += 1

    close_start, close_stop = @str\find @close_tag, @pos, true
    unless close_start
      return nil, @error_for_pos start, "failed to find closing tag"

    while @in_string @pos, close_start
      close_start, close_stop = @str\find @close_tag, close_stop, true

    trim_newline = if "-" == @str\sub close_start - 1, close_start - 1
      close_start -= 1
      true

    @push_code modifier or "code", @pos, close_start - 1

    @pos = close_stop + 1

    if trim_newline
      if match = @str\match "^\n", @pos
        @pos += #match

    true

  -- see if stop leaves us in the middle of a string
  in_string: (start, stop) =>
    in_string = false
    end_delim = nil
    escape = false

    pos = 0
    skip_until = nil

    chunk = @str\sub start, stop
    for char in chunk\gmatch "."
      pos += 1

      if skip_until
        continue if pos <= skip_until
        skip_until = nil

      if end_delim
        if end_delim == char and not escape
          in_string = false
          end_delim = nil
      else
        if char == "'" or char == '"'
          end_delim = char
          in_string = true

        if char == "["
          if lstring = chunk\match "^%[=*%[", pos
            lstring_end = lstring\gsub "%[", "]"
            lstring_p1, lstring_p2 = chunk\find lstring_end, pos, true
            -- no closing lstring, must be inside string
            return true unless lstring_p1
            skip_until = lstring_p2

      escape = char == "\\"

    in_string

  push_raw: (start, stop) =>
    insert @chunks, @str\sub start, stop

  push_code: (kind, start, stop) =>
    insert @chunks, {
      kind, @str\sub(start, stop), start
    }

  compile: (str) =>
    success, err = @parse str
    return nil, err unless success
    @load @chunks_to_lua!, "elua", str

  parse: (@str) =>
    assert type(@str) == "string", "expecting string for parse"
    @pos = 1
    @chunks = {}

    while true
      found, err = @next_tag!
      return nil, err if err
      break unless found

    true

  parse_error: (err, code) =>
    line_no, err_msg = err\match "%[.-%]:(%d+): (.*)$"
    line_no = tonumber line_no

    return unless line_no

    line = get_line code, line_no
    source_pos = tonumber line\match "^%-%-%[%[(%d+)%]%]"

    return unless source_pos
    @error_for_pos source_pos, err_msg

  error_for_pos: (source_pos, err_msg) =>
    source_line_no = pos_to_line @str, source_pos
    source_line = get_line @str, source_line_no
    "#{err_msg} [#{source_line_no}]: #{source_line}"

  load: (code, name="elua") =>
    code_fn = coroutine.wrap ->
      coroutine.yield code

    fn, err = load code_fn, name

    unless fn
      -- try to extract meaningful error message
      if err_msg = @parse_error err, code
        return nil, err_msg

      return nil, err

    (env={}) ->
      combined_env = setmetatable {}, __index: (name) =>
        val = env[name]
        val = _G[name] if val == nil
        val

      setfenv fn, combined_env
      fn tostring, concat, html_escape

  -- generates the code of the template
  chunks_to_lua: =>
    -- todo: find a no-conflict name for buffer
    buffer = {
      "local _b, _b_i, _tostring, _concat, _escape = {}, 0, ..."
    }
    buffer_i = #buffer

    push = (str) ->
      buffer_i += 1
      buffer[buffer_i] = str

    for chunk in *@chunks
      t = type chunk
      t = chunk[1] if t == "table"
      switch t
        when "string"
          push "_b_i = _b_i + 1"
          push "_b[_b_i] = #{("%q")\format(chunk)}"
        when "code"
          push "--[[#{chunk[3]}]] " .. chunk[2]
        when "=", "-"
          assign = "_tostring(#{chunk[2]})"

          if t == "=" and @html_escape
            assign = "_escape(" .. assign .. ")"

          assign = "_b[_b_i] = " .. assign

          push "_b_i = _b_i + 1"
          push "--[[#{chunk[3]}]] " .. assign
        else
          error "unknown type #{t}"

    push "return _concat(_b)"
    concat buffer, "\n"

compile = Parser!\compile

render = (str, env) ->
  fn, err = compile(str)
  if fn
    fn env
  else
    nil, err

{ :compile, :render, :Parser }

