defmodule Foxbus.MixProject do
  use Mix.Project

  def project do
    [
      app: :foxbus,
      version: "0.1.1",
      # The Nest runs Elixir 1.17 on OTP 26: build with that toolchain
      # (source nest_gen2_sdk/platform/host_env.sh).
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: [
        nest_gen2_dep(),
        {:floki, "~> 0.38"}
      ]
    ]
  end

  # The SDK from Hex, or a local path for co-development (set NEST_GEN2_PATH
  # when working on both repos at once). "~> 0.1.0", not "~> 0.1" — the
  # trailing .0 matters, since "~> 0.1" alone would also allow a breaking 0.2
  # before 1.0.
  defp nest_gen2_dep do
    case System.get_env("NEST_GEN2_PATH") do
      nil -> {:nest_gen2, "~> 0.1.0"}
      path -> {:nest_gen2, path: path}
    end
  end

  # Settings live here rather than in config/*.exs: on the Nest the app is
  # started from plain erl, which only sees the .app file's env.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Foxbus.Application, []},
      env: [
        # TEMPORARY: Coleshill (040000002201/2) is closed by a Carousel notice
        # until Tuesday (see the live "Service 105 Disruption" affecting these
        # exact stops) — pointed at Holtspur instead meanwhile, a stop pair
        # verified clear of any current closure notice. Revert to Coleshill
        # once 105 is back to normal.
        stops: [
          {:towards_uxbridge, "040000001207", "To Uxbridge"},
          {:towards_wycombe, "040000001208", "To High Wycombe"}
        ],
        arrivals_source: Foxbus.Adapters.Sources.CarouselScrapeSource,
        arrivals_sink: Foxbus.Adapters.Sinks.ScreensSink,
        # Holtspur is shared with 102/103 too; watching both 104 and 105 shows
        # them interleaved and filters the other two off the board.
        lines: ["104", "105"],
        disruptions_source: Foxbus.Adapters.Sources.CarouselDisruptionsSource,
        disruptions_sink: Foxbus.Adapters.Sinks.ScreensSink,
        stop_closure_source: Foxbus.Adapters.Sources.CarouselStopClosureSource,
        stop_closure_sink: Foxbus.Adapters.Sinks.ScreensSink,
        # TEMPORARY: the fake, until nest_gen2 0.2.0 (NestGen2.Wifi) ships —
        # swap to Foxbus.Adapters.Sources.NestGen2WifiSource once it's live.
        wifi_source: Foxbus.Adapters.Sources.FakeWifiSource,
        assets_dir: "/media/scratch/.nest_gen2_sdk/foxbus",
        # Runtime override file (route, stops, default screen) — see
        # Foxbus.Config. nil means "config.exs next to assets_dir".
        config_path: nil,
        screen_step_degrees: 45
      ]
    ]
  end
end
