defmodule Foxbus.Adapters.Sources.StubSource do
  @moduledoc "Fixed sample arrivals, for developing without the network."
  @behaviour Foxbus.Ports.ArrivalsSource

  alias Foxbus.Domain.Arrival

  @impl true
  def fetch_arrivals(_stop_id) do
    now = Foxbus.LondonTime.now()

    {:ok,
     for {line, destination, minutes, status} <- [
           {"105", "Chesham Broadway", 4, :live},
           {"1", "High Wycombe", 17, :scheduled},
           {"105", "Chesham + Chartridg", 42, :scheduled}
         ] do
       due = NaiveDateTime.add(now, minutes * 60, :second)

       %Arrival{
         line: line,
         destination: destination,
         eta_minutes: minutes,
         status: status,
         scheduled_time: Time.new!(due.hour, due.minute, 0)
       }
     end}
  end
end
