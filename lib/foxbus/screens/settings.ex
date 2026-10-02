defmodule Foxbus.Screens.Settings do
  @moduledoc """
  The settings UI's own state machine: opened by pressing the dial on the
  splash screen, closed by "Back" from the menu or by ~60 s idle (the idle
  timer itself lives in `Foxbus.Screens`, same as the main auto-advance one).

  Pure functions only, same philosophy as `Foxbus.Screens.Layout` — nothing
  here touches the network or the display; `Foxbus.Screens` calls `select/1`,
  gets back an `effect` naming the side effect it owes (kick off a scan or a
  connect attempt, as a `Task` — never inline, since both can block for
  seconds), performs it, and reports the result back with `scan_result/2` or
  `connect_result/2`.

  Screens, in order: `:menu` -> `:scanning` -> `:networks` -> (`:password` if
  the chosen network is secured and not already saved) -> `:connecting` ->
  `:result`, with "Back"/cancel paths returning to `:menu` or `:networks`.

  Known simplification: no "Other…" (hidden SSID) entry on the networks
  screen yet — the spec marks it optional. The password screen always shows
  the last typed character unmasked rather than "for a second" — Screens
  would need its own timer to un-mask-then-mask, which isn't built here.
  """

  alias Foxbus.Ports.WifiSource

  @type screen :: :menu | :scanning | :networks | :password | :connecting | :result
  @type wheel_group :: :upper | :lower | :digits | :symbols
  @type wheel_entry :: {:char, String.t()} | {:switch, wheel_group} | :delete | :done | :cancel

  @type t :: %__MODULE__{
          screen: screen,
          highlight: non_neg_integer,
          wifi_status: WifiSource.status(),
          versions: %{foxbus: String.t(), sdk: String.t()},
          networks: [WifiSource.network()],
          selected_network: WifiSource.network() | nil,
          password: String.t(),
          wheel_group: wheel_group,
          wheel_index: non_neg_integer,
          connect_result: {:ok, map} | {:error, term} | nil
        }

  @type effect :: :exit_to_splash | :scan | {:connect, String.t(), String.t() | nil} | nil

  defstruct screen: :menu,
            highlight: 0,
            wifi_status: %{state: :unavailable, ssid: nil, ip: nil, signal_dbm: nil},
            versions: %{foxbus: "", sdk: ""},
            networks: [],
            selected_network: nil,
            password: "",
            wheel_group: :upper,
            wheel_index: 0,
            connect_result: nil

  @menu_items [:change_wifi, :back]
  @result_items [:retry, :back]

  @groups %{
    upper: String.graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
    lower: String.graphemes("abcdefghijklmnopqrstuvwxyz"),
    digits: String.graphemes("0123456789"),
    symbols: String.graphemes("!@#$%^&*()-_=+")
  }
  @group_order [:upper, :lower, :digits, :symbols]
  @group_labels %{upper: "ABC", lower: "abc", digits: "123", symbols: "#+="}

  @doc "Opens the menu screen, with the Wi-Fi status and versions to show."
  @spec open(WifiSource.status(), %{foxbus: String.t(), sdk: String.t()}) :: t
  def open(wifi_status, versions),
    do: %__MODULE__{wifi_status: wifi_status, versions: versions}

  @doc "A live :wifi event while settings is open — refreshes the shown status."
  @spec wifi_updated(t, WifiSource.status()) :: t
  def wifi_updated(settings, status), do: %{settings | wifi_status: status}

  @doc "Moves the highlight or wheel position one step; wraps at the ends."
  @spec navigate(t, :cw | :ccw) :: t
  def navigate(%{screen: :menu} = s, dir), do: move_highlight(s, dir, length(@menu_items))

  def navigate(%{screen: :networks} = s, dir),
    do: move_highlight(s, dir, length(s.networks) + 1)

  def navigate(%{screen: :password} = s, dir) do
    entries = wheel_entries(s.wheel_group)
    step = if dir == :cw, do: 1, else: -1
    %{s | wheel_index: Integer.mod(s.wheel_index + step, length(entries))}
  end

  def navigate(%{screen: :result, connect_result: {:error, _}} = s, dir),
    do: move_highlight(s, dir, length(@result_items))

  def navigate(s, _dir), do: s

  defp move_highlight(s, dir, count) do
    step = if dir == :cw, do: 1, else: -1
    %{s | highlight: Integer.mod(s.highlight + step, count)}
  end

  @doc "A button press: returns the new state, and any side effect owed by the caller."
  @spec select(t) :: {t, effect}
  def select(%{screen: :menu} = s) do
    case Enum.at(@menu_items, s.highlight) do
      :change_wifi -> {%{s | screen: :scanning}, :scan}
      :back -> {s, :exit_to_splash}
    end
  end

  def select(%{screen: :networks} = s) do
    cond do
      s.highlight == length(s.networks) ->
        {%{s | screen: :menu, highlight: 0}, nil}

      true ->
        network = Enum.at(s.networks, s.highlight)
        s = %{s | selected_network: network}

        if network.secured and not network.saved do
          {%{s | screen: :password, password: "", wheel_group: :upper, wheel_index: 0}, nil}
        else
          {%{s | screen: :connecting}, {:connect, network.ssid, nil}}
        end
    end
  end

  def select(%{screen: :password} = s) do
    case Enum.at(wheel_entries(s.wheel_group), s.wheel_index) do
      {:char, c} ->
        {%{s | password: s.password <> c}, nil}

      {:switch, group} ->
        {%{s | wheel_group: group, wheel_index: 0}, nil}

      :delete ->
        {%{s | password: String.slice(s.password, 0, max(String.length(s.password) - 1, 0))}, nil}

      :done ->
        ssid = s.selected_network.ssid
        {%{s | screen: :connecting}, {:connect, ssid, s.password}}

      :cancel ->
        {%{s | screen: :networks, highlight: 0}, nil}
    end
  end

  def select(%{screen: :scanning} = s), do: {s, nil}
  def select(%{screen: :connecting} = s), do: {s, nil}

  def select(%{screen: :result, connect_result: {:ok, _}} = s), do: {%{s | screen: :menu}, nil}

  def select(%{screen: :result, connect_result: {:error, _}} = s) do
    case Enum.at(@result_items, s.highlight) do
      :back ->
        {%{s | screen: :networks, highlight: 0}, nil}

      :retry ->
        network = s.selected_network

        if network.secured and not network.saved do
          {%{s | screen: :password, password: "", wheel_group: :upper, wheel_index: 0}, nil}
        else
          {%{s | screen: :connecting}, {:connect, network.ssid, nil}}
        end
    end
  end

  @doc "A scan Task finished — moves to the networks screen either way."
  @spec scan_result(t, {:ok, [WifiSource.network()]} | {:error, term}) :: t
  def scan_result(s, {:ok, networks}),
    do: %{s | screen: :networks, networks: networks, highlight: 0}

  def scan_result(s, {:error, _reason}), do: %{s | screen: :networks, networks: [], highlight: 0}

  @doc "A connect Task finished — moves to the result screen."
  @spec connect_result(t, {:ok, map} | {:error, term}) :: t
  def connect_result(s, result), do: %{s | screen: :result, connect_result: result, highlight: 0}

  @doc "The wheel's entries for a group: its characters, then the other groups' switches, then controls."
  @spec wheel_entries(wheel_group) :: [wheel_entry]
  def wheel_entries(group) do
    chars = @groups |> Map.fetch!(group) |> Enum.map(&{:char, &1})
    switches = @group_order |> Kernel.--([group]) |> Enum.map(&{:switch, &1})
    chars ++ switches ++ [:delete, :done, :cancel]
  end

  @doc "A short label for a wheel entry, for the character wheel display."
  @spec wheel_label(wheel_entry) :: String.t()
  def wheel_label({:char, c}), do: c
  def wheel_label({:switch, group}), do: Map.fetch!(@group_labels, group)
  def wheel_label(:delete), do: "⌫"
  def wheel_label(:done), do: "✓"
  def wheel_label(:cancel), do: "✗"
end
