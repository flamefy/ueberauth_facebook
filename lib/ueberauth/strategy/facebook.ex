defmodule Ueberauth.Strategy.Facebook do
  @moduledoc """
  Facebook Strategy for Überauth.
  """

  use Ueberauth.Strategy,
    default_scope: "email,public_profile",
    profile_fields: "id,email,gender,link,locale,name,timezone,updated_time,verified",
    uid_field: :id,
    allowed_request_params: [
      :auth_type,
      :scope,
      :locale,
      :state,
      :display
    ]

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  require Logger
  @doc """
  Handles initial request for Facebook authentication.
  """
  def handle_request!(conn) do
    allowed_params = conn
      |> option(:allowed_request_params)
      |> Enum.map(&to_string/1)

    # opts = oauth_client_options_from_conn(conn)
    Logger.warn("****strat fb *handle_request opts************")

    authorize_url = conn.params
      |> maybe_replace_param(conn, "auth_type", :auth_type)
      |> maybe_replace_param(conn, "scope", :default_scope)
      |> maybe_replace_param(conn, "state", :state)
      |> maybe_replace_param(conn, "display", :display)
      |> Enum.filter(fn {k, _v} -> Enum.member?(allowed_params, k) end)
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Keyword.put(:redirect_uri, callback_url(conn))
      |> Ueberauth.Strategy.Facebook.OAuth.authorize_url!(conn: conn)

    redirect!(conn, authorize_url)
  end

  @doc """
  Handles the callback from Facebook.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    # opts = oauth_client_options_from_conn(conn)
    opts = [redirect_uri: callback_url(conn), conn: conn]
    Logger.warn("****strat fb  handle_callback************code******* #{inspect(code, pretty: true)}")

    try do
      Logger.warn("****strat fb  handle_callback************try do***before client****")
      client = Ueberauth.Strategy.Facebook.OAuth.get_token!([code: code], opts)
      Logger.warn("****strat fb  handle_callback************try do*******")
      token = client.token
      Logger.warn("****strat fb  handle_callback************try do****token*** #{inspect(token)}")

      if token.access_token == nil do
        err = token.other_params["error"]
        desc = token.other_params["error_description"]
        set_errors!(conn, [error(err, desc)])
      else
        Logger.warn("****strat fb  handle_callback************before fetch_user*******")
        fetch_user(conn, client, [])
      end
    rescue
      OAuth2.Error ->
        set_errors!(conn, [error("invalid_code", "The code has been used or has expired")])
    end
  end

  @doc """
  Handles the Facebook callback from mobile.
  """
  def handle_mobile_callback(conn, %{token: token}) when is_binary(token) do
    opts = oauth_client_options_from_conn(conn)

    token = OAuth2.AccessToken.new(token)
    client = Ueberauth.Strategy.Facebook.OAuth.client([token: token])
    query = user_query(conn, client.token, [])

    path = "/me?#{query}"
    case OAuth2.Client.get(client, path) do
      {:ok, %OAuth2.Response{status_code: status_code, body: user}} when status_code in 200..299 ->
        {:ok, auth(user, token)}
      {:ok, %OAuth2.Response{status_code: 401, body: body}} ->
        {:error, body["error"]["message"]}
      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, reason}
      _other ->
        {:error, :internal_server_error}
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:facebook_user, nil)
    |> put_private(:facebook_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.facebook_user[uid_field]
  end

  @doc """
  Includes the credentials from the facebook response.
  """
  def credentials(conn) do
    token = conn.private.facebook_token
    scopes = token.other_params["scope"] || ""
    scopes = String.split(scopes, ",")

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of the
  `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.facebook_user
    %Info{
      description: user["bio"],
      email: user["email"],
      first_name: user["first_name"],
      image: fetch_image(user["id"]),
      last_name: user["last_name"],
      name: user["name"],
      urls: %{
        facebook: user["link"],
        website: user["website"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from
  the facebook callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.facebook_token,
        user: conn.private.facebook_user
      }
    }
  end

  defp fetch_image(uid) do
    "https://graph.facebook.com/#{uid}/picture?type=large"
  end

  defp fetch_user(conn, client, config) do
    Logger.warn("****strat fb  fetch_user********start****")
    conn = put_private(conn, :facebook_token, client.token)
    query = user_query(conn, client.token, config)
    path = "/me?#{query}"

    Logger.warn("****strat fb  fetch_user********before case****")
    case OAuth2.Client.get(client, path) do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        Logger.warn("****strat fb  fetch_user***********case 401****")
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        Logger.warn("****strat fb  handle_callback************ case do 200-399****status_code*** #{inspect(status_code)}")
        Logger.warn("****strat fb  handle_callback************ case do 200-399****user*** #{inspect(user, pretty: true)}")
        put_private(conn, :facebook_user, user)

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp user_query(conn, token, []) do
    %{"appsecret_proof" => appsecret_proof(token, conn)}
    |> Map.merge(query_params(conn, :locale))
    |> Map.merge(query_params(conn, :profile))
    |> URI.encode_query()
  end
  defp user_query(conn, token, config) do
    %{"appsecret_proof" => appsecret_proof(token, config)}
    |> Map.merge(query_params(conn, :locale))
    |> Map.merge(query_params(conn, :profile))
    |> URI.encode_query()
  end

  defp appsecret_proof(token, conn) do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Facebook.OAuth)
         |> compute_config(conn)
    client_secret = Keyword.get(config, :client_secret)
    token.access_token
    |> hmac(:sha256, client_secret)
    |> Base.encode16(case: :lower)
  end
  # defp appsecret_proof(token, config) do
  #   client_secret = Keyword.get(config, :client_secret)
  #   token.access_token
  #   |> hmac(:sha256, client_secret)
  #   |> Base.encode16(case: :lower)
  # end

  defp compute_config(config, conn) do
    with module when is_atom(module) <- Keyword.get(config, :client_secret),
        {:module, _} <- Code.ensure_loaded(module),
        true <- function_exported?(module, :get_client_secret, 1)
    do
      config |> Keyword.put(:client_secret, apply(module, :get_client_secret, [conn]))
    else
      _ -> config
    end
  end

  defp hmac(data, type, key) do
    :crypto.hmac(type, key, data)
  end

  defp query_params(conn, :profile) do
    case option(conn, :profile_fields) do
      nil -> %{}
      profile -> %{"fields" => profile}
    end
  end

  defp query_params(conn, :locale) do
    case option(conn, :locale) do
      nil -> %{}
      locale -> %{"locale" => locale}
    end
  end

  defp option(conn, key) do
    default = Keyword.get(default_options(), key)
    case options(conn) do
      nil ->
        default
      opts ->
        Keyword.get(opts, key, default)
    end
  end

  defp option(nil, conn, key), do: option(conn, key)
  defp option(value, _conn, _key), do: value

  defp maybe_replace_param(params, conn, name, config_key) do
    if params[name] || is_nil(option(params[name], conn, config_key)) do
      params
    else
      Map.put(
        params,
        name,
        option(params[name], conn, config_key)
      )
    end
  end

  defp oauth_client_options_from_conn(conn) do
    base_options = [redirect_uri: callback_url(conn), conn: conn]
    request_options = conn.private[:ueberauth_request_options].options

    case {request_options[:client_id], request_options[:client_secret]} do
      {nil, _} -> base_options
      {_, nil} -> base_options
      {id, secret} -> [client_id: id, client_secret: secret] ++ base_options
    end
  end

  defp auth(user, %OAuth2.AccessToken{} = token) do
    %Ueberauth.Auth{
      provider: :facebook,
      strategy: Ueberauth.Strategy.Facebook,
      uid: get_uid(user),
      info: get_info_from_user(user),
      extra: extra(user, token),
      credentials: get_credentials(token)
    }
  end

  def get_uid(%{"id" => id} = _user), do: id

  def get_info_from_user(user) do
    %Info{
      description: user["bio"],
      email: user["email"],
      first_name: user["first_name"],
      image: fetch_image(user["id"]),
      last_name: user["last_name"],
      name: user["name"],
      urls: %{
        facebook: user["link"],
        website: user["website"]
      }
    }
  end

  def extra(user, token) do
    %Extra{
      raw_info: %{
        token: token,
        user: user
      }
    }
  end

  def get_credentials(%OAuth2.AccessToken{other_params: other_params} = token) do
    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: other_params
              |> Map.get("scope", "")
              |> String.split(","),
      token: token.access_token
    }
  end
end
