import AppKit
let folder=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let n=size*scale, f=CGFloat(n)
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:n,pixelsHigh:n,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
  func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ radius:CGFloat)->NSBezierPath {
   NSBezierPath(roundedRect:NSRect(x:x*f,y:y*f,width:w*f,height:h*f),xRadius:radius*f,yRadius:radius*f)
  }
  let tile=rect(0.07,0.07,0.86,0.86,0.20)
  NSGradient(colors:[NSColor(calibratedRed:0.24,green:0.36,blue:0.69,alpha:1),NSColor(calibratedRed:0.055,green:0.12,blue:0.29,alpha:1)])!.draw(in:tile,angle:270)
  NSGraphicsContext.saveGraphicsState();tile.addClip()
  NSColor.white.withAlphaComponent(0.06).setFill();rect(0.07,0.52,0.86,0.43,0.20).fill()
  NSGraphicsContext.restoreGraphicsState()
  NSColor.white.withAlphaComponent(0.15).setStroke();tile.lineWidth=f*0.008;tile.stroke()
  // Upright game cases and a horizontal shelf form the library mark.
  let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.22);shadow.shadowBlurRadius=f*0.025;shadow.shadowOffset=NSSize(width:0,height:-f*0.015)
  NSGraphicsContext.saveGraphicsState();shadow.set()
  NSGradient(starting:NSColor(calibratedWhite:1,alpha:1),ending:NSColor(calibratedRed:0.74,green:0.83,blue:0.98,alpha:1))!.draw(in:rect(0.24,0.32,0.145,0.39,0.025),angle:270)
  NSGradient(starting:NSColor(calibratedRed:0.78,green:0.92,blue:1,alpha:1),ending:NSColor(calibratedRed:0.37,green:0.66,blue:0.92,alpha:1))!.draw(in:rect(0.405,0.32,0.145,0.44,0.025),angle:270)
  let transform=AffineTransform(translationByX:f*0.57,byY:f*0.32);var lean=transform;lean.rotate(byDegrees:12)
  NSGraphicsContext.saveGraphicsState();(lean as NSAffineTransform).concat()
  let card=NSBezierPath(roundedRect:NSRect(x:0,y:0,width:f*0.145,height:f*0.36),xRadius:f*0.025,yRadius:f*0.025)
  NSGradient(starting:NSColor(calibratedRed:0.95,green:0.78,blue:0.51,alpha:1),ending:NSColor(calibratedRed:0.87,green:0.52,blue:0.32,alpha:1))!.draw(in:card,angle:270)
  NSGraphicsContext.restoreGraphicsState()
  NSColor(calibratedRed:0.83,green:0.9,blue:1,alpha:1).setFill();rect(0.205,0.255,0.59,0.045,0.022).fill()
  NSGraphicsContext.restoreGraphicsState()
  NSColor(calibratedRed:0.16,green:0.27,blue:0.48,alpha:0.8).setFill()
  rect(0.28,0.59,0.065,0.018,0.009).fill();rect(0.445,0.64,0.065,0.018,0.009).fill()
  NSColor.white.withAlphaComponent(0.96).setFill()
  let play=NSBezierPath();play.move(to:NSPoint(x:f*0.445,y:f*0.43));play.line(to:NSPoint(x:f*0.445,y:f*0.55));play.line(to:NSPoint(x:f*0.513,y:f*0.49));play.close();play.fill()
  NSGraphicsContext.restoreGraphicsState()
  let suffix=scale==2 ? "@2x":""
  try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder+"/icon_\(size)x\(size)\(suffix).png"))
 }
}
