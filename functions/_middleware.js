// coolinterpreter.com 首页显示 App 介绍页；fangyitogo-app.pages.dev 首页仍是网页版翻译工具。
export async function onRequest(ctx) {
  const url = new URL(ctx.request.url);
  const host = url.hostname.toLowerCase();
  if (host === "www.coolinterpreter.com") {
    url.hostname = "coolinterpreter.com";
    return Response.redirect(url.toString(), 301);
  }
  if (host === "coolinterpreter.com" && (url.pathname === "/" || url.pathname === "/index.html")) {
    const page = await ctx.env.ASSETS.fetch(new URL("/landing", url));
    const headers = new Headers(page.headers);
    headers.set("Cache-Control", "public, max-age=300");
    return new Response(page.body, { status: 200, headers });
  }
  return ctx.next();
}
