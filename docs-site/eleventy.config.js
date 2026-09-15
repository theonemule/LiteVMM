// The documentation site is deliberately independent of VMAPI's runtime.
// Build output is ignored by source control and can be hosted on any static server.
export default function (eleventyConfig) {
  eleventyConfig.addPassthroughCopy({ "src/assets": "assets" });
  return { dir: { input: "src", includes: "_includes", output: "_site" }, markdownTemplateEngine: "njk" };
}
