import GRDB
import ReerCodable

struct ImageProcessorModel {
    var id: String
    var type: String
    var order: Int
    var isEnabled: Bool
    var configuration: Configuration

    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)
            $0.column("type", .text).notNull()
            $0.column("order", .integer).notNull()
            $0.column("isEnabled", .boolean).notNull()
            $0.column("configuration", .text).notNull()
        }
    }
}

extension ImageProcessorModel: TableRecord { static let databaseTableName = "imageprocessor" }

extension ImageProcessorModel: Codable, FetchableRecord, PersistableRecord {}

extension ImageProcessorModel {
    struct Configuration: Codable {
        var aggressiveness: Double?
        var context: Int?
        var threshold: Double?
        var color: String?
        var intensity: Double?
        var serverURL: String?
        var metadata: RemoteMetadata?
        var configValues: [ConfigValue]?
        var username: String?
        var password: String?
    }

    @Codable struct RemoteMetadata {
        let id: String
        let name: String?
        let version: String?
        let description: String?
        @DecodingDefault([]) let authors: [String]
        let repository: String?
        @DecodingDefault(false) let authenticationEnabled: Bool
        @DecodingDefault([]) let configs: [Config]
    }
}
