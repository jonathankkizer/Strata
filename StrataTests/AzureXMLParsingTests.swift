import Testing
import Foundation
@testable import Strata

@Suite("Azure XML parsing")
struct AzureXMLParsingTests {

    // MARK: - ContainerListXMLParser

    @Test("Valid container list XML parses two containers")
    func containerListTwoContainers() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Containers>
            <Container><Name>foo</Name></Container>
            <Container><Name>bar</Name></Container>
          </Containers>
          <NextMarker/>
        </EnumerationResults>
        """
        let result = try ContainerListXMLParser().parse(Data(xml.utf8))
        #expect(result.containers.count == 2)
        let names = result.containers.map(\.name)
        #expect(names.contains("foo"))
        #expect(names.contains("bar"))
    }

    @Test("Empty NextMarker element is returned as nil")
    func containerListEmptyNextMarkerIsNil() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Containers>
            <Container><Name>only</Name></Container>
          </Containers>
          <NextMarker/>
        </EnumerationResults>
        """
        let result = try ContainerListXMLParser().parse(Data(xml.utf8))
        #expect(result.nextMarker == nil)
    }

    @Test("Non-empty NextMarker element is returned as its string value")
    func containerListNonEmptyNextMarker() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Containers>
            <Container><Name>alpha</Name></Container>
          </Containers>
          <NextMarker>abc</NextMarker>
        </EnumerationResults>
        """
        let result = try ContainerListXMLParser().parse(Data(xml.utf8))
        #expect(result.nextMarker == "abc")
    }

    // MARK: - BlobListXMLParser

    @Test("Blob list XML with full properties parses one blob and one prefix")
    func blobListOneBlobOnePrefix() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Blobs>
            <Blob>
              <Name>images/cat.png</Name>
              <Properties>
                <Content-Length>4096</Content-Length>
                <Content-Type>image/png</Content-Type>
                <Last-Modified>Wed, 21 Oct 2015 07:28:00 GMT</Last-Modified>
                <AccessTier>Hot</AccessTier>
                <Etag>0x8D3CE90D48EF57D</Etag>
              </Properties>
            </Blob>
            <BlobPrefix>
              <Name>folder/</Name>
            </BlobPrefix>
          </Blobs>
          <NextMarker/>
        </EnumerationResults>
        """
        let result = try BlobListXMLParser().parse(Data(xml.utf8))
        #expect(result.objects.count == 2)

        let blob = try #require(result.objects.first { !$0.isPrefix })
        #expect(blob.key == "images/cat.png")
        #expect(blob.size == 4096)
        #expect(blob.contentType == "image/png")
        #expect(blob.storageClass == "Hot")
        #expect(blob.etag == "0x8D3CE90D48EF57D")
        #expect(blob.isPrefix == false)

        // Verify RFC1123 date parses to year 2015
        let lastModified = try #require(blob.lastModified)
        let cal = Calendar(identifier: .gregorian)
        var utcComponents = DateComponents()
        utcComponents.timeZone = TimeZone(identifier: "GMT")
        let year = cal.component(.year, from: lastModified)
        #expect(year == 2015)

        let prefix = try #require(result.objects.first { $0.isPrefix })
        #expect(prefix.key == "folder/")
        #expect(prefix.isPrefix == true)
    }

    @Test("Blob list nextMarker is nil when element is empty")
    func blobListEmptyNextMarkerIsNil() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Blobs/>
          <NextMarker/>
        </EnumerationResults>
        """
        let result = try BlobListXMLParser().parse(Data(xml.utf8))
        #expect(result.nextMarker == nil)
    }

    @Test("Malformed XML throws an error")
    func malformedXMLThrows() {
        let badData = Data("not xml <<<".utf8)
        #expect(throws: (any Error).self) {
            try ContainerListXMLParser().parse(badData)
        }
    }

    @Test("Blob with only Name and no Properties produces size 0 and nil contentType")
    func blobMissingPropertiesHasDefaults() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Blobs>
            <Blob>
              <Name>bare.txt</Name>
            </Blob>
          </Blobs>
          <NextMarker/>
        </EnumerationResults>
        """
        let result = try BlobListXMLParser().parse(Data(xml.utf8))
        #expect(result.objects.count == 1)
        let blob = try #require(result.objects.first)
        #expect(blob.key == "bare.txt")
        #expect(blob.size == 0)
        #expect(blob.contentType == nil)
        #expect(blob.isPrefix == false)
    }
}
