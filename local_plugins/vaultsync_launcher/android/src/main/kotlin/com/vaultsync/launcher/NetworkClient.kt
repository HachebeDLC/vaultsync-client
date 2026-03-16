package com.vaultsync.launcher

import org.json.JSONObject
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Handles synchronous HTTP networking for file uploads and downloads.
 */
class NetworkClient {
    
    /**
     * Performs a POST request with a raw byte array body (or subset of it).
     */
    fun postRaw(url: String, token: String?, headers: Map<String, String>, data: ByteArray, offset: Int, length: Int): Int {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setFixedLengthStreamingMode(length.toLong())
            setRequestProperty("Content-Type", "application/octet-stream")
            token?.let { setRequestProperty("Authorization", "Bearer $it") }
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
            connectTimeout = 10000
            readTimeout = 30000
        }
        
        connection.outputStream.use { it.write(data, offset, length) }
        return connection.responseCode
    }

    /**
     * Performs a POST request with a JSON body.
     */
    fun postJson(url: String, token: String?, body: JSONObject): Int {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            token?.let { setRequestProperty("Authorization", "Bearer $it") }
            connectTimeout = 10000
            readTimeout = 30000
        }
        
        connection.outputStream.use { it.write(body.toString().toByteArray()) }
        return connection.responseCode
    }

    /**
     * Opens a connection for downloading, returning the connection object for stream management.
     */
    fun openDownloadConnection(url: String, token: String?, body: JSONObject): HttpURLConnection {
        return (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            token?.let { setRequestProperty("Authorization", "Bearer $it") }
            connectTimeout = 10000
            readTimeout = 30000
            outputStream.use { it.write(body.toString().toByteArray()) }
        }
    }
}
