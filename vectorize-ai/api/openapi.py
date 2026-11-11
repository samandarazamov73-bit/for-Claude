"""OpenAPI 3.0.3 document for the public API, generated from the same
option tables the server uses to parse requests."""
from __future__ import annotations

from export_engine import EXPORT_SPECS, ExportOptions
from vectorization_engine import OPTION_SPECS, ProcessingOptions

from .errors import error_table

RESULT_TYPES = ["image/svg+xml", "application/pdf", "application/postscript", "application/dxf", "image/png"]


def _schema(kind: str, extra=None, default=None, desc: str = "") -> dict:
    if kind == "boolean":
        s = {"type": "boolean"}
    elif kind == "integer":
        s = {"type": "integer"}
    elif kind == "number":
        s = {"type": "number"}
    elif kind == "enum":
        s = {"type": "string", "enum": list(extra)}
    else:
        s = {"type": "string"}
    if default is not None:
        s["default"] = default
    if desc:
        s["description"] = desc
    return s


def _processing_props() -> dict:
    d = ProcessingOptions()
    props = {}
    for spec in OPTION_SPECS:
        s = _schema(spec.kind, spec.enum, getattr(d, spec.attr), spec.description)
        if spec.minimum is not None:
            s["minimum"] = spec.minimum
        if spec.maximum is not None:
            s["maximum"] = spec.maximum
        props[spec.name] = s
    return props


def _output_props() -> dict:
    d = ExportOptions()
    props = {}
    for name, attr, kind, extra, desc in EXPORT_SPECS:
        s = _schema(kind, extra if kind == "enum" else None, getattr(d, attr), desc)
        if kind == "number":
            s["minimum"], s["maximum"] = extra
        props[name] = s
    return props


def _error_responses() -> dict:
    ref = {"$ref": "#/components/responses/Error"}
    return {"400": ref, "401": ref, "402": ref, "404": ref, "413": ref, "415": ref, "429": ref, "500": ref, "503": ref, "504": ref}


def build_openapi(server_url: str) -> dict:
    result_content = {t: {"schema": {"type": "string", "format": "binary"}} for t in RESULT_TYPES}
    credit_headers = {
        "X-Credits-Charged": {"description": "Credits deducted for this call.", "schema": {"type": "string"}},
        "X-Credits-Calculated": {"description": "Credits this call costs (also for free test calls).", "schema": {"type": "string"}},
    }
    vec_props = {
        "image": {"type": "string", "format": "binary", "description": "Image file (PNG, JPEG, GIF, BMP, WebP, TIFF; max 30 MiB, 33,554,432 px)."},
        "image.url": {"type": "string", "format": "uri", "description": "Public http(s) URL the server downloads the image from (private networks are blocked)."},
        "image.base64": {"type": "string", "description": "Base64 (or data: URL) encoded image, at most 1 MB decoded."},
        "image.token": {"type": "string", "description": "Token of a previously uploaded image (returned in X-Image-Token when policy.retention_days > 0)."},
        "mode": {"type": "string", "enum": ["production", "preview", "test", "test_preview"], "default": "production", "description": "production: 1 credit; preview: 0.2 credits, watermarked PNG up to 4x size; test / test_preview: free, heavily watermarked."},
        "policy.retention_days": {"type": "integer", "minimum": 0, "maximum": 30, "default": 0, "description": "Days to keep the image and result for /download and image.token reuse. First day free, then 0.01 credits/day."},
    }
    vec_props.update(_processing_props())
    vec_props.update(_output_props())
    dl_props = {
        "image.token": {"type": "string"},
        "receipt": {"type": "string", "description": "X-Receipt from /vectorize; required to upgrade a preview (0.9 credits)."},
    }
    dl_props.update(_output_props())
    return {
        "openapi": "3.0.3",
        "info": {
            "title": "Vectorize AI API",
            "version": "1.0.0",
            "description": (
                "Convert raster images (PNG, JPEG, GIF, BMP, WebP, TIFF) into SVG, PDF, EPS, DXF or PNG.\n\n"
                "Authenticate with HTTP Basic: the **API Id** is the user name and the **API Secret** the password. "
                "Create keys on your account page. Requests are `multipart/form-data`; results are returned as the file.\n\n"
                "Errors are JSON: `{\"error\": {\"status\": 400, \"code\": 2001, \"message\": \"...\"}}`. "
                "On HTTP 429 wait for `Retry-After`; for batch jobs start with 5 parallel requests and add one every 5 minutes."
            ),
        },
        "servers": [{"url": server_url}],
        "security": [{"basicAuth": []}],
        "paths": {
            "/api/v1/vectorize": {
                "post": {
                    "operationId": "vectorize",
                    "summary": "Vectorize an image",
                    "requestBody": {"required": True, "content": {"multipart/form-data": {"schema": {"type": "object", "properties": vec_props}}}},
                    "responses": {
                        "200": {
                            "description": "The vectorized result in the requested format.",
                            "headers": {
                                **credit_headers,
                                "X-Image-Token": {"description": "Present when policy.retention_days > 0.", "schema": {"type": "string"}},
                                "X-Receipt": {"description": "Receipt for /download (e.g. preview upgrade).", "schema": {"type": "string"}},
                            },
                            "content": result_content,
                        },
                        **_error_responses(),
                    },
                }
            },
            "/api/v1/download": {
                "post": {
                    "operationId": "download",
                    "summary": "Download a retained result (upgrade a preview or another format)",
                    "description": "Upgrading a preview costs 0.9 credits; each additional format of a production result costs 0.1 credits; test results are free and watermarked.",
                    "requestBody": {"required": True, "content": {"multipart/form-data": {"schema": {"type": "object", "required": ["image.token"], "properties": dl_props}}}},
                    "responses": {"200": {"description": "The result file.", "headers": credit_headers, "content": result_content}, **_error_responses()},
                }
            },
            "/api/v1/delete": {
                "post": {
                    "operationId": "delete",
                    "summary": "Delete a retained image immediately",
                    "requestBody": {"required": True, "content": {"multipart/form-data": {"schema": {"type": "object", "required": ["image.token"], "properties": {"image.token": {"type": "string"}}}}}},
                    "responses": {"200": {"description": "Deleted.", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/DeleteResult"}}}}, **_error_responses()},
                }
            },
            "/api/v1/account": {
                "get": {
                    "operationId": "account",
                    "summary": "Subscription status and credit balance",
                    "responses": {"200": {"description": "Account status.", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Account"}}}}, **_error_responses()},
                }
            },
        },
        "components": {
            "securitySchemes": {"basicAuth": {"type": "http", "scheme": "basic", "description": "API Id as user name, API Secret as password."}},
            "schemas": {
                "Error": {
                    "type": "object",
                    "required": ["error"],
                    "properties": {
                        "error": {
                            "type": "object",
                            "required": ["status", "code", "message"],
                            "properties": {"status": {"type": "integer"}, "code": {"type": "integer"}, "message": {"type": "string"}},
                        }
                    },
                },
                "Account": {
                    "type": "object",
                    "properties": {"subscriptionPlan": {"type": "string"}, "subscriptionState": {"type": "string"}, "credits": {"type": "number"}},
                },
                "DeleteResult": {"type": "object", "properties": {"success": {"type": "boolean"}}},
            },
            "responses": {"Error": {"description": "Error (see the error code table).", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}},
        },
        "x-error-codes": error_table(),
    }
