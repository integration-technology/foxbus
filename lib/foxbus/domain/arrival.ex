defmodule Foxbus.Domain.Arrival do
  @moduledoc """
  One upcoming bus at a stop: the shape every arrivals source produces.
  """

  @enforce_keys [:line, :destination, :eta_minutes, :status]
  defstruct [:line, :destination, :eta_minutes, :status, :delay_minutes, :scheduled_time]

  @type status :: :live | :scheduled

  @type t :: %__MODULE__{
          line: String.t(),
          destination: String.t(),
          eta_minutes: non_neg_integer,
          status: status,
          delay_minutes: integer | nil,
          scheduled_time: Time.t() | nil
        }

  @countdown_threshold_minutes 10

  @doc "Arrivals ordered soonest first."
  @spec sort_by_eta([t]) :: [t]
  def sort_by_eta(arrivals), do: Enum.sort_by(arrivals, & &1.eta_minutes)

  @doc """
  How to show when the bus is due: a countdown once it is close enough that a
  minute matters (10 minutes or less), otherwise the clock time to look for.
  """
  @spec eta_text(t) :: String.t()
  def eta_text(%__MODULE__{eta_minutes: m}) when m <= @countdown_threshold_minutes, do: "#{m} min"
  def eta_text(%__MODULE__{scheduled_time: nil, eta_minutes: m}), do: "#{m} min"

  def eta_text(%__MODULE__{scheduled_time: %Time{} = t}),
    do: "at " <> (t |> Time.to_string() |> String.slice(0, 5))
end
