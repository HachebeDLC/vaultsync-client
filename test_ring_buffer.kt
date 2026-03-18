import java.nio.ByteBuffer

fun main() {
    val expectedBlockSize = 1048615
    val ringBuffer = ByteBuffer.allocate(expectedBlockSize * 2)
    val block = ByteArray(expectedBlockSize)
    
    // Simulate reading 1382094 bytes in chunks
    var totalRead = 0
    val totalSize = 1382094
    val chunkSize = 65536
    
    var outputSize = 0
    var loops = 0
    while (totalRead < totalSize) {
        val readCount = Math.min(chunkSize, totalSize - totalRead)
        totalRead += readCount
        
        val chunk = ByteArray(readCount)
        ringBuffer.put(chunk, 0, readCount)
        ringBuffer.flip()
        
        while (ringBuffer.remaining() >= expectedBlockSize) {
            ringBuffer.get(block, 0, expectedBlockSize)
            outputSize += 1048576 // Decrypted length
            println("Processed full block. Total output: $outputSize")
        }
        
        ringBuffer.compact()
        loops++
    }
    
    ringBuffer.flip()
    val remaining = ringBuffer.remaining()
    if (remaining > 0) {
        ringBuffer.get(block, 0, remaining)
        outputSize += (remaining - 23) // Simulated decryption
        println("Processed partial block. Total output: $outputSize")
    }
}
