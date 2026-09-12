"""
StreamableHTTP Client Transport with OAuth2 (Cognito) Authentication

This module extends the MCP StreamableHTTPTransport to add OAuth2 authentication
for MCP servers that authenticate using Cognito client credentials flow.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Generator
import time

import httpx
from anyio.streams.memory import MemoryObjectReceiveStream, MemoryObjectSendStream
from mcp.client.streamable_http import (
    GetSessionIdCallback,
    StreamableHTTPTransport,
    streamablehttp_client,
)
from mcp.shared._httpx_utils import McpHttpClientFactory, create_mcp_http_client
from mcp.shared.message import SessionMessage


class OAuth2HTTPXAuth(httpx.Auth):
    """HTTPX Auth class that handles OAuth2 token management and adds Bearer token to requests."""

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        token_endpoint: str,
    ):
        self.client_id = client_id
        self.client_secret = client_secret
        self.token_endpoint = token_endpoint
        self.access_token = None
        self.token_expiry = 0

    def _get_access_token(self) -> str:
        """Fetch a new access token using client credentials flow."""
        # Check if we have a valid token
        if self.access_token and time.time() < self.token_expiry:
            return self.access_token

        # Request a new token
        with httpx.Client() as client:
            response = client.post(
                self.token_endpoint,
                auth=(self.client_id, self.client_secret),
                data={
                    "grant_type": "client_credentials",
                },
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
            response.raise_for_status()
            token_data = response.json()
            
            self.access_token = token_data["access_token"]
            # Set expiry with a 5-minute buffer
            expires_in = token_data.get("expires_in", 3600)
            self.token_expiry = time.time() + expires_in - 300
            
            return self.access_token

    def auth_flow(
        self, request: httpx.Request
    ) -> Generator[httpx.Request, httpx.Response, None]:
        """Adds the OAuth2 Bearer token to the request headers."""
        
        # Get a valid access token
        access_token = self._get_access_token()
        
        # Add the Bearer token to the Authorization header
        request.headers["Authorization"] = f"Bearer {access_token}"
        
        yield request


class StreamableHTTPTransportWithOAuth2(StreamableHTTPTransport):
    """
    Streamable HTTP client transport with OAuth2 (Cognito) authentication support.

    This transport enables communication with MCP servers that authenticate using
    Cognito client credentials flow.
    """

    def __init__(
        self,
        url: str,
        client_id: str,
        client_secret: str,
        token_endpoint: str,
        headers: dict[str, str] | None = None,
        timeout: float | timedelta = 30,
        sse_read_timeout: float | timedelta = 60 * 5,
    ) -> None:
        """Initialize the StreamableHTTP transport with OAuth2 authentication.

        Args:
            url: The endpoint URL.
            client_id: OAuth2 client ID.
            client_secret: OAuth2 client secret.
            token_endpoint: OAuth2 token endpoint URL.
            headers: Optional headers to include in requests.
            timeout: HTTP timeout for regular operations.
            sse_read_timeout: Timeout for SSE read operations.
        """
        # Initialize parent class with OAuth2 auth handler
        super().__init__(
            url=url,
            headers=headers,
            timeout=timeout,
            sse_read_timeout=sse_read_timeout,
            auth=OAuth2HTTPXAuth(client_id, client_secret, token_endpoint),
        )

        self.client_id = client_id
        self.client_secret = client_secret
        self.token_endpoint = token_endpoint


@asynccontextmanager
async def streamablehttp_client_with_oauth2(
    url: str,
    client_id: str,
    client_secret: str,
    token_endpoint: str,
    headers: dict[str, str] | None = None,
    timeout: float | timedelta = 30,
    sse_read_timeout: float | timedelta = 60 * 5,
    terminate_on_close: bool = True,
    httpx_client_factory: McpHttpClientFactory = create_mcp_http_client,
) -> AsyncGenerator[
    tuple[
        MemoryObjectReceiveStream[SessionMessage | Exception],
        MemoryObjectSendStream[SessionMessage],
        GetSessionIdCallback,
    ],
    None,
]:
    """
    Client transport for Streamable HTTP with OAuth2 (Cognito) authentication.

    This transport enables communication with MCP servers that authenticate using
    Cognito client credentials flow.

    Args:
        url: The MCP gateway endpoint URL
        client_id: OAuth2 client ID
        client_secret: OAuth2 client secret
        token_endpoint: OAuth2 token endpoint URL
        headers: Optional headers to include in requests
        timeout: HTTP timeout for regular operations
        sse_read_timeout: Timeout for SSE read operations
        terminate_on_close: Whether to terminate the session on close
        httpx_client_factory: Factory for creating HTTPX clients

    Yields:
        Tuple containing:
            - read_stream: Stream for reading messages from the server
            - write_stream: Stream for sending messages to the server
            - get_session_id_callback: Function to retrieve the current session ID
    """

    async with streamablehttp_client(
        url=url,
        headers=headers,
        timeout=timeout,
        sse_read_timeout=sse_read_timeout,
        terminate_on_close=terminate_on_close,
        httpx_client_factory=httpx_client_factory,
        auth=OAuth2HTTPXAuth(client_id, client_secret, token_endpoint),
    ) as result:
        yield result
