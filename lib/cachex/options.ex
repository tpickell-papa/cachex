defmodule Cachex.Options do
  @moduledoc false
  # A container to ensure that all option parsing is done in a single location
  # to avoid accidentally getting mixed field names and values across the library.

  # add some aliases
  alias Cachex.Hook
  alias Cachex.Limit
  alias Cachex.Util
  alias Cachex.Util.Names

  @doc """
  Parses a list of input options to the fields we care about, setting things like
  defaults and verifying types.

  The output of this function will be an instance of a Cachex State, that we can
  use blindly in other areas of the library. As such, this function has the
  potential to become a little messy - but that's okay, since it saves us trying
  to duplicate this logic all over the codebase.
  """
  def parse(cache, options) when is_list(options) do
    with { :ok,   ets_result } <- setup_ets(cache, options),
         { :ok, limit_result } <- setup_limit(cache, options),
         { :ok,  hook_result } <- setup_hooks(cache, options, limit_result),
         { :ok, trans_result } <- setup_transactions(cache, options),
         { :ok,    fb_result } <- setup_fallbacks(cache, options),
         { :ok,   ttl_result } <- setup_ttl_components(cache, options)
      do
        { pre_hooks, post_hooks } = hook_result
        { transactional, manager } = trans_result
        { fallback, fallback_args } = fb_result
        { default_ttl, ttl_interval, janitor } = ttl_result

        state = %Cachex.State{
          "cache": cache,
          "disable_ode": !!options[:disable_ode],
          "ets_opts": ets_result,
          "default_ttl": default_ttl,
          "fallback": fallback,
          "fallback_args": fallback_args,
          "janitor": janitor,
          "limit": limit_result,
          "manager": manager,
          "pre_hooks": pre_hooks,
          "post_hooks": post_hooks,
          "transactions": transactional,
          "ttl_interval": ttl_interval
        }

        { :ok, state }
      end
  end
  def parse(cache, _options),
  do: parse(cache, [])

  # Sets up and fallback behaviour options. Currently this just retrieves the
  # two flags from the options list and returns them inside a tuple for storage.
  defp setup_fallbacks(_cache, options) do
    fb_opts = {
      Util.get_opt(options, :fallback, &is_function/1),
      Util.get_opt(options, :fallback_args, &is_list/1, [])
    }
    { :ok, fb_opts }
  end

  # Sets up any hooks to be enabled for this cache. Also parses out whether a
  # Stats hook has been requested or not. The returned value is a tuple of pre
  # and post hooks as they're stored separately.
  defp setup_hooks(cache, options, limit) do
    stats_hook = options[:record_stats] && %Hook{
      module: Cachex.Hook.Stats,
      server_args: [
        name: Names.stats(cache)
      ]
    }

    hooks_list =
      options
      |> Keyword.get(:hooks, [])
      |> List.wrap

    hooks =
      limit
      |> Limit.to_hooks
      |> List.insert_at(0, stats_hook)
      |> Enum.concat(hooks_list)

    with { :ok, hooks } <- Hook.validate(hooks) do
      groups = {
        Hook.group_by_type(hooks, :pre),
        Hook.group_by_type(hooks, :post)
      }

      { :ok, groups }
    end
  end

  # Parses out a potential cache size limit to cap the cache at. This will return
  # a Limit struct based on the provided values. If the cache has no limits, the
  # `:limit` key in the struct will be nil.
  defp setup_limit(_cache, options) do
    limit =
      options
      |> Keyword.get(:limit)
      |> Limit.parse

    { :ok, limit }
  end

  # Parses out a potential list of ETS options, passing through the default opts
  # used for concurrency settings. This allows them to be overridden, but it would
  # have to be explicitly overridden.
  defp setup_ets(_cache, options) do
    ets_opts =
      options
      |> Util.get_opt(:ets_opts, &is_list/1, [])
      |> Keyword.put_new(:write_concurrency, true)
      |> Keyword.put_new(:read_concurrency, true)

    { :ok, ets_opts }
  end

  # Parses out whether the user wishes to utilize transactions or not. They can
  # either be enabled or disabled, represented by `true` and `false`.
  defp setup_transactions(cache, options) do
    trans_opts = {
      Util.get_opt(options, :transactions, &is_boolean/1, false),
      Names.manager(cache)
    }
    { :ok, trans_opts }
  end

  # Sets up and parses any options related to TTL behaviours. Currently this deals
  # with janitor naming, TTL defaults, and purge intervals.
  defp setup_ttl_components(cache, options) do
    janitor_name = Names.janitor(cache)

    default_ttl  = Util.get_opt(options, :default_ttl, fn(val) ->
      is_integer(val) and val > 0
    end)

    ttl_interval = Util.get_opt(options, :ttl_interval, fn(val) ->
      is_integer(val) and val >= -1
    end)

    opts = case ttl_interval do
      nil when default_ttl != nil ->
        { default_ttl, :timer.seconds(3), janitor_name }
      val when val > -1 ->
        { default_ttl, val, janitor_name }
      _na ->
        { default_ttl, nil, nil }
    end

    { :ok, opts }
  end

end
