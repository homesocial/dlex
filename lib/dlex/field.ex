defmodule Dlex.Field do
  @type type ::
          :uid | :boolean | :float | :geo | :integer | :password | :string | :utc_datetime | :auto

  @type t :: %__MODULE__{
          name: atom(),
          type: type(),
          db_name: String.t(),
          alter: map() | nil,
          opts: Keyword.t()
        }

  defstruct [:name, :type, :db_name, :alter, :opts]
end
