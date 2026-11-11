"""Error model shared by the web API and the public REST API.

Every error response has the shape::

    {"error": {"status": 413, "code": 2004, "message": "..."}}

The public API uses the numeric codes below (documented in OpenAPI); the
internal web API uses the string keys."""
from __future__ import annotations

from dataclasses import dataclass

from fastapi.responses import JSONResponse


@dataclass(frozen=True)
class ErrorDef:
    numeric: int
    status: int
    description: str


ERRORS: dict[str, ErrorDef] = {
    # authentication / account
    "unauthorized": ErrorDef(1001, 401, "Missing or invalid API credentials (HTTP Basic: API Id / API Secret)."),
    "key_revoked": ErrorDef(1002, 401, "The API key has been revoked."),
    "insufficient_credits": ErrorDef(1003, 402, "Not enough credits for this operation."),
    "subscription_required": ErrorDef(1004, 402, "An active subscription is required."),
    "rate_limited": ErrorDef(1005, 429, "Too many requests; retry after the Retry-After delay."),
    "payload_too_large": ErrorDef(1006, 413, "Request body exceeds the size limit."),
    "not_authenticated": ErrorDef(1007, 401, "Sign in required."),
    "forbidden": ErrorDef(1008, 403, "You do not have access to this resource."),
    # image input
    "missing_image": ErrorDef(2001, 400, "Provide exactly one of image, image.url, image.base64 or image.token."),
    "multiple_images": ErrorDef(2002, 400, "More than one image input was provided."),
    "unsupported_format": ErrorDef(2003, 415, "Unsupported image format (PNG, JPEG, GIF, BMP, WebP, TIFF)."),
    "file_too_large": ErrorDef(2004, 413, "Image file exceeds 30 MiB."),
    "too_many_pixels": ErrorDef(2005, 413, "Image exceeds 33,554,432 pixels."),
    "corrupt_image": ErrorDef(2006, 400, "The image could not be decoded."),
    "format_mismatch": ErrorDef(2006, 400, "The file content does not match a supported image format."),
    "empty_file": ErrorDef(2006, 400, "The uploaded file is empty."),
    "url_fetch_failed": ErrorDef(2007, 400, "The image URL could not be downloaded."),
    "url_unresolvable": ErrorDef(2007, 400, "The image URL host could not be resolved."),
    "url_not_allowed": ErrorDef(2008, 400, "The image URL is not allowed (private network, port or scheme)."),
    "invalid_url": ErrorDef(2008, 400, "The image URL is invalid."),
    "invalid_base64": ErrorDef(2009, 400, "image.base64 is not valid base64 or exceeds 1 MB."),
    "image_not_found": ErrorDef(2010, 404, "Unknown or expired image token."),
    "invalid_receipt": ErrorDef(2011, 400, "The receipt does not match this image."),
    "invalid_crop": ErrorDef(2012, 400, "The crop rectangle is invalid."),
    # parameters
    "invalid_option": ErrorDef(3001, 400, "A processing parameter is invalid."),
    "invalid_output_option": ErrorDef(3002, 400, "An output parameter is invalid."),
    "invalid_mode": ErrorDef(3003, 400, "mode must be production, preview, test or test_preview."),
    "output_too_large": ErrorDef(3004, 400, "The requested output size is too large."),
    "invalid_request": ErrorDef(3005, 400, "The request is malformed."),
    # processing
    "processing_error": ErrorDef(4001, 500, "Vectorization failed."),
    "timeout": ErrorDef(4002, 504, "Processing exceeded the time budget."),
    "cancelled": ErrorDef(4003, 409, "Processing was cancelled."),
    "not_ready": ErrorDef(4004, 409, "The result is not ready yet."),
    "invalid_input": ErrorDef(4005, 400, "The input could not be processed."),
    "out_of_memory": ErrorDef(4006, 507, "The image needs more memory than is available."),
    "worker_crashed": ErrorDef(4007, 500, "The worker process crashed repeatedly."),
    "interrupted": ErrorDef(4008, 500, "The server restarted during processing."),
    # infrastructure (negative codes)
    "overloaded": ErrorDef(-3, 503, "Workers are overloaded; additional capacity is being added. Retry shortly."),
    "internal_timeout": ErrorDef(-10, 504, "Internal timeout."),
    "internal_error": ErrorDef(-1, 500, "Unexpected server error."),
    "payments_not_configured": ErrorDef(-20, 503, "Payments are not configured on this server."),
    "not_found": ErrorDef(-404, 404, "Not found."),
    "csrf": ErrorDef(-403, 403, "Missing X-Requested-With header."),
}


class ApiError(Exception):
    def __init__(self, key: str, message: str | None = None, status: int | None = None, headers: dict | None = None):
        d = ERRORS.get(key, ERRORS["internal_error"])
        super().__init__(message or d.description)
        self.key = key
        self.message = message or d.description
        self.status = status or d.status
        self.numeric = d.numeric
        self.headers = headers or {}

    def response(self, numeric: bool) -> JSONResponse:
        body = {"error": {"status": self.status, "code": self.numeric if numeric else self.key, "message": self.message}}
        return JSONResponse(body, status_code=self.status, headers=self.headers)


def error_table() -> list[dict]:
    seen = set()
    out = []
    for key, d in ERRORS.items():
        if (d.numeric, d.status) in seen:
            continue
        seen.add((d.numeric, d.status))
        out.append({"code": d.numeric, "status": d.status, "key": key, "description": d.description})
    return sorted(out, key=lambda r: (r["code"] < 0, abs(r["code"])))
