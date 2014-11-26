# The debug is based on Better Errors, under MIT LICENSE.
#
# Copyright (c) 2012 Charlie Somerville
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

defmodule Plug.Debugger do
  @moduledoc """
  A module (not a plug) for debugging in development.

  The module is commonly used within a `Plug.Builder` or a `Plug.Router`
  and it wraps the `call/2` function:

      defmodule MyApp do
        use Plug.Builder

        if Mix.env == :dev do
          use Plug.Debugger, otp_app: :my_app
        end

        plug :boom

        def boom(conn, _) do
          # Error raised here will be caught and displayed in a debug
          # page complete with a stacktrace and other helpful info
          raise "oops"
        end
      end

  Notice `Plug.Debugger` *does not* catch errors, as errors should still
  propagate so the Elixir process finishes with the proper reason.
  This module does not perform any logging either, as all logging is done
  by the web server handler.

  ## PLUG_EDITOR

  If a PLUG_EDITOR environment variable is set, `Plug.Debugger` is going
  to use it to generate links to your text editor. The variable should be
  set with __FILE__ and __LINE__ placeholders which will be correctly
  replaced, for example:

      txmt://open/?url=file://__FILE__&line=__LINE__

  ## Manual usage

  One can also manually use `Plug.Debugger` by invoking the `wrap/3`
  function directly.
  """

  @already_sent {:plug_conn, :sent}
  import Plug.Conn

  @doc false
  defmacro __using__(opts) do
    quote do
      @plug_debugger unquote(opts)

      def call(conn, opts) do
        Plug.Debugger.wrap(conn, @plug_debugger, fn -> super(conn, opts) end)
      end

      defoverridable [call: 2]
    end
  end

  @doc """
  Wraps a given function and renders a nice error page
  in case the function fails.

  ## Options

    * `:otp_app` - the name of the OTP application considered
      to be the main application

  """
  def wrap(conn, opts, fun) do
    try do
      fun.()
    catch
      kind, error ->
        stack = System.stacktrace

        receive do
          @already_sent ->
            send self(), @already_sent
            :erlang.raise kind, error, stack
        after
          0 ->
            render conn, kind, error, stack, opts
            :erlang.raise kind, error, stack
        end
    end
  end

  ## Rendering

  require EEx
  EEx.function_from_file :def, :template, "lib/plug/templates/debugger.eex", [:assigns]

  # Made public with @doc false for testing.
  @doc false
  def render(conn, kind, error, stack, opts) do
    error = Exception.normalize(kind, error, stack)
    {status, title, message} = info(kind, error)
    send_resp conn, status, template(conn: conn, frames: frames(stack, opts),
                                     title: title, message: message)
  end

  defp info(:error, error) do
    {Plug.Exception.status(error), error.__struct__, Exception.message(error)}
  end

  defp info(:throw, throw) do
    {500, "unhandled throw", inspect(throw)}
  end

  defp info(:exit, exit) do
    {500, "unhandled exit", Exception.format_exit(exit)}
  end

  defp frames(stacktrace, opts) do
    app    = opts[:otp_app]
    editor = System.get_env("PLUG_EDITOR")

    stacktrace
    |> Enum.take_while(& elem(&1, 0) != __MODULE__)
    |> Enum.map_reduce(0, &each_frame(&1, &2, app, editor))
    |> elem(0)
  end

  defp each_frame(entry, index, root, editor) do
    {module, info, location, app} = get_entry(entry)
    {file, line} = {to_string(location[:file] || "nofile"), location[:line]}

    source  = get_source(module, file)
    context = get_context(root, app)
    snippet = get_snippet(source, line)

    {%{app: app,
       info: info,
       file: file,
       line: line,
       context: context,
       snippet: snippet,
       index: index,
       link: editor && get_editor(source, line, editor)
     }, index + 1}
  end

  # From :elixir_compiler_*
  defp get_entry({module, :__MODULE__, 0, location}) do
    {module, inspect(module) <> " (module)", location, get_app(module)}
  end

  # From :elixir_compiler_*
  defp get_entry({_module, :__MODULE__, 1, location}) do
    {nil, "(module)", location, nil}
  end

  # From :elixir_compiler_*
  defp get_entry({_module, :__FILE__, 1, location}) do
    {nil, "(file)", location, nil}
  end

  defp get_entry({module, fun, arity, location}) do
    {module, Exception.format_mfa(module, fun, arity), location, get_app(module)}
  end

  defp get_entry({fun, arity, location}) do
    {nil, Exception.format_fa(fun, arity), location, nil}
  end

  defp get_app(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end

  defp get_context(app, app) when app != nil, do: :app
  defp get_context(_app1, _app2),             do: :all

  defp get_source(module, file) do
    if Code.ensure_loaded?(module) &&
       (source = module.__info__(:compile)[:source]) do
      to_string(source)
    else
      file
    end
  end

  defp get_editor(file, line, editor) do
    editor = :binary.replace(editor, "__FILE__", URI.encode(Path.expand(file)))
    editor = :binary.replace(editor, "__LINE__", to_string(line))
    h(editor)
  end

  @radius 5

  def get_snippet(file, line) do
    if File.regular?(file) and is_integer(line) do
      to_discard = max(line - @radius - 1, 0)
      lines = File.stream!(file) |> Stream.take(line + 5) |> Stream.drop(to_discard)

      {first_five, lines} = Enum.split(lines, line - to_discard - 1)
      first_five = with_line_number first_five, to_discard + 1, false

      {center, last_five} = Enum.split(lines, 1)
      center = with_line_number center, line, true
      last_five = with_line_number last_five, line + 1, false

      first_five ++ center ++ last_five
    end
  end

  defp with_line_number(lines, initial, highlight) do
    Enum.map_reduce(lines, initial, fn(line, acc) ->
      {{acc, line, highlight}, acc + 1}
    end) |> elem(0)
  end

  ## Helpers

  defp path(%Plug.Conn{path_info: []}),   do: "/"
  defp path(%Plug.Conn{path_info: path}), do: Enum.reduce(path, [], fn(i, acc) -> [acc, ?/, i] end)

  defp method(%Plug.Conn{method: method}), do: method

  defp h(string) do
    for <<code <- to_string(string)>> do
      << case code do
           ?& -> "&amp;"
           ?< -> "&lt;"
           ?> -> "&gt;"
           ?" -> "&quot;"
           _  -> <<code>>
         end :: binary >>
    end
  end
end
