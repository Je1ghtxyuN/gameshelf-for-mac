import Foundation
@main struct CoverArtTests {
 static func main() throws {
  precondition(CoverArt.query("[汉化] CLANNAD v1.2-pc")=="CLANNAD")
  precondition(CoverArt.key("Clannad: Full Voice")==CoverArt.key("CLANNAD Full Voice"))
  let a=CoverMatch(title:"CLANNAD",aliases:["クラナド"],image:URL(string:"https://t.vndb.org/cv/1.jpg")!,page:URL(string:"https://vndb.org/v4")!,source:"VNDB")
  precondition(CoverArt.exact([a],query:"クラナド")?.title=="CLANNAD")
  precondition(CoverArt.exact([a],query:"CLANNAD Side Stories")==nil)
  precondition(CoverArt.exact([a,a],query:"CLANNAD")==nil)
  precondition(CoverArt.allowedImage(URL(string:"https://t.vndb.org/cv/1.jpg")!))
  precondition(!CoverArt.allowedImage(URL(string:"http://t.vndb.org/cv/1.jpg")!))
  precondition(!CoverArt.allowedImage(URL(string:"https://t.vndb.org.evil.test/cv/1.jpg")!))
  let other=CoverMatch(title:"CLANNAD",aliases:[],image:a.image,page:a.page,source:"Steam",steamID:123)
  precondition(CoverArt.exact(CoverArt.merge([a],[other]),query:"CLANNAD")==nil)
  var linked=a;linked.steamID=123
  precondition(CoverArt.merge([linked],[other]).count==1)
  precondition(!CoverArt.allowedRedirect(from:a.image,to:URL(string:"https://example.com/x")!))
  precondition(CoverArt.allowedRedirect(from:a.image,to:URL(string:"https://s.vndb.org/cv/x.jpg")!))
  precondition(CoverArt.steamID("https://store.steampowered.com/app/324160/")==324160)
  let fixture=Data(#"{"results":[{"id":"v4","title":"CLANNAD","titles":[{"title":"クラナド"}],"image":{"thumbnail":"https://t.vndb.org/cv/1.jpg","sexual":0}},{"id":"v5","title":"Other","image":null}]}"#.utf8)
  let parsed=try CoverArt.parseVNDB(fixture);precondition(parsed.count==1)
  print("PASS CoverArt matching, ambiguity, aliases, image hosts and missing images")
 }
}
