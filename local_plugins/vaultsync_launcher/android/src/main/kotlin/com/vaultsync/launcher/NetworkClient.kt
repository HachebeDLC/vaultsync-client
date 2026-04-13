package com.vaultsync.launcher

import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.InputStream
import java.util.concurrent.TimeUnit

/**
 * Handles optimized HTTP networking using OkHttp with connection pooling.
 */
class NetworkClient {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .connectionPool(ConnectionPool(5, 5, TimeUnit.MINUTES))
        .build()

    /**
     * Performs a POST request with a raw byte array body.
     */
    fun postRaw(url: String, token: String?, headers: Map<String, String>, data: ByteArray, offset: Int, length: Int): Int {
        val mediaType = "application/octet-stream".toMediaType()
        val body = data.toRequestBody(mediaType, offset, length)
        
        val requestBuilder = Request.Builder()
            .url(url)
            .post(body)
        
        token?.let { requestBuilder.addHeader("Authorization", "Bearer $it") }
        headers.forEach { (k, v) -> requestBuilder.addHeader(k, v) }
        
        client.newCall(requestBuilder.build()).execute().use { response ->
            return response.code
        }
    }

    /**
     * Performs a POST request with a JSON body.
     */
    fun postJson(url: String, token: String?, body: JSONObject, headers: Map<String, String>? = null): Int {
        val mediaType = "application/json".toMediaType()
        val requestBody = body.toString().toRequestBody(mediaType)
        
        val requestBuilder = Request.Builder()
            .url(url)
            .post(requestBody)
        
        token?.let { requestBuilder.addHeader("Authorization", "Bearer $it") }
        headers?.forEach { (k, v) -> requestBuilder.addHeader(k, v) }
        
        client.newCall(requestBuilder.build()).execute().use { response ->
            return response.code
        }
    }

    /**
     * Wrapper for a download response to maintain API compatibility.
     */
    class DownloadConnection(val responseCode: Int, val inputStream: InputStream, private val response: Response) : AutoCloseable {
        override fun close() {
            response.close()
        }
    }

    /**
     * Opens a connection for downloading.
     */
    fun openDownloadConnection(url: String, token: String?, body: JSONObject): DownloadConnection {
        val mediaType = "application/json".toMediaType()
        val requestBody = body.toString().toRequestBody(mediaType)
        
        val requestBuilder = Request.Builder()
            .url(url)
            .post(requestBody)
        
        token?.let { requestBuilder.addHeader("Authorization", "Bearer $it") }
        
        val response = client.newCall(requestBuilder.build()).execute()
        return DownloadConnection(response.code, response.body?.byteStream() ?: "".byteInputStream(), response)
    }
}
