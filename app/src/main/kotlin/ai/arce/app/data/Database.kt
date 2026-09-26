package ai.arce.app.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * One chat. [snapshotJson] is a serialized ai.arce.core.chat.ConversationSnapshot; large
 * data (models, generated files) stays on disk, never in the database (spec §54).
 */
@Entity(tableName = "conversations")
data class ConversationEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val updatedAt: Long,
    val snapshotJson: String,
    /** True while a generation runs; still true on the next launch means it was interrupted (spec §25.1). */
    val generating: Boolean,
    /** Model, backend and settings used, for reproducing a generation (spec §16). */
    val environmentJson: String = "",
)

/** A permission the user granted in the consent window (spec: 権限ウィンドウ). */
@Entity(tableName = "consents")
data class ConsentEntity(
    @PrimaryKey val scope: String,
    val grantedAt: Long,
    val always: Boolean,
)

@Dao
interface ConversationDao {
    @Query("SELECT * FROM conversations ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<ConversationEntity>>

    @Query("SELECT * FROM conversations WHERE id = :id")
    suspend fun get(id: Long): ConversationEntity?

    @Query("SELECT * FROM conversations WHERE generating = 1 ORDER BY updatedAt DESC LIMIT 1")
    suspend fun interrupted(): ConversationEntity?

    @Upsert
    suspend fun upsert(entity: ConversationEntity): Long

    @Query("UPDATE conversations SET generating = 0 WHERE id = :id")
    suspend fun clearGenerating(id: Long)

    @Query("DELETE FROM conversations WHERE id = :id")
    suspend fun delete(id: Long)
}

@Dao
interface ConsentDao {
    @Query("SELECT * FROM consents")
    fun observeAll(): Flow<List<ConsentEntity>>

    @Query("SELECT * FROM consents WHERE scope = :scope")
    suspend fun get(scope: String): ConsentEntity?

    @Upsert
    suspend fun upsert(entity: ConsentEntity)

    @Query("DELETE FROM consents WHERE scope = :scope")
    suspend fun revoke(scope: String)
}

@Database(entities = [ConversationEntity::class, ConsentEntity::class], version = 1, exportSchema = false)
abstract class ArceDatabase : RoomDatabase() {
    abstract fun conversations(): ConversationDao
    abstract fun consents(): ConsentDao

    companion object {
        fun create(context: Context): ArceDatabase =
            Room.databaseBuilder(context, ArceDatabase::class.java, "arce.db").build()
    }
}
