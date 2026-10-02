defmodule Foxbus.MixProject do
  use Mix.Project

  def project do
    [
      app: :foxbus,
      version: "0.1.0",
      # The Nest runs Elixir 1.17 on OTP 26: build with that toolchain
      # (source nest_gen2_sdk/platform/host_env.sh).
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: [
        {:nest_gen2, path: "../nest_gen2_sdk"},
        {:floki, "~> 0.38"}
      ]
    ]
  end

  # Settings live here rather than in config/*.exs: on the Nest the app is
  # started from plain erl, which only sees the .app file's env.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Foxbus.Application, []},
      env: [
        stops: [
          {:chesham, "040000002201", "To Chesham"},
          {:high_wycombe, "040000002202", "To High Wycombe"}
        ],
        arrivals_source: Foxbus.Adapters.Sources.CarouselScrapeSource,
        arrivals_sink: Foxbus.Adapters.Sinks.ScreensSink,
        lines: ["105"],
        disruptions_source: Foxbus.Adapters.Sources.CarouselDisruptionsSource,
        disruptions_sink: Foxbus.Adapters.Sinks.ScreensSink,
        stop_closure_source: Foxbus.Adapters.Sources.CarouselStopClosureSource,
        stop_closure_sink: Foxbus.Adapters.Sinks.ScreensSink,
        assets_dir: "/media/scratch/.nest_gen2_sdk/foxbus",
        # Runtime override file (route, stops, default screen) — see
        # Foxbus.Config. nil means "config.exs next to assets_dir".
        config_path: nil,
        screen_step_degrees: 45
      ]
    ]
  end
end
