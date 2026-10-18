#include <algorithm>
#include <future>
#include <iostream>
#include <map>
#include <nlohmann/json.hpp>
#include <vector>
using json = nlohmann::json;
#include "grounded.h"
#define REQUIRE(x)                                                             \
  do {                                                                         \
    if (!(x))                                                                  \
      throw std::runtime_error(#x);                                            \
  } while (0)
struct Fake {
  std::vector<std::string> replies;
  size_t cursor = 0;
  size_t tokens(const std::string &text) {
    return icu::UnicodeString::fromUTF8(text).countChar32();
  }
  std::string generate(const std::string &, int, bool) {
    return replies.at(cursor++);
  }
};
int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--validate") {
    std::string line;
    while (std::getline(std::cin, line)) {
      const auto input = json::parse(line);
      auto errors = grounding::validate_draft(
          input.at("text"),
          input.at("evidence").get<std::map<std::string, std::string>>());
      std::cout << json(errors).dump() << std::endl;
    }
    return 0;
  }
  using namespace grounding;
  try {
    const auto compiled = pattern("(?i)cache fixture");
    REQUIRE(pattern("(?i)cache fixture") == compiled);
    auto concurrent = std::async(std::launch::async, [compiled] {
      return pattern("(?i)cache fixture") == compiled &&
             has("CACHE FIXTURE", "(?i)cache fixture");
    });
    REQUIRE(concurrent.get());
    REQUIRE(!has("other text", "(?i)cache fixture"));
    std::map<std::string, std::string> evidence{
        {"S1", "Mira leads Atlas. Montreal consultation: Sept 2019. Duration "
               "12–24 months; dose 100 mg; efficacy >95%; cost <$3."},
        {"S2", "The planning meeting is Friday."}};
    REQUIRE(validate_draft(
                "Mira leads Atlas. Consultation: September 2019. Dose 100 mg; "
                "duration 12–24 months; efficacy >95%; cost <$3. [S1]",
                evidence)
                .empty());
    for (auto bad :
         {"Montreal consultation: Sept 207. [S1]", "Duration 124 months. [S1]",
          "Duration 12–24 days. [S1]", "Duration 24–12 months. [S1]",
          "Efficacy <95%. [S1]", "Cost <€3. [S1]", "Mira leads Atlas. [S2]",
          "Mira leads Atlas. [S99]", "Mira leads Atlas."})
      REQUIRE(!validate_draft(bad, evidence).empty());
    evidence = {{"S1", "Mira leads Atlas."}, {"S2", "Launch 2024."}};
    REQUIRE(
        !validate_draft("Mira leads Atlas. [S1]\n\nLaunch 2024. [S1]", evidence)
             .empty());
    REQUIRE(
        validate_draft("Mira leads Atlas. [S1]\n\nLaunch 2024. [S2]", evidence)
            .empty());
    REQUIRE(!validate_draft("| Item | Value |\n|---|---|\n| Launch | 2024 [S1] "
                            "|\n| Lead | Mira leads Atlas [S2] |",
                            evidence)
                 .empty());
    evidence = {
        {"S1", "Cost <$3. These are historical targets, not current prices."}};
    REQUIRE(!validate_draft("Cost <$3. [S1]", evidence).empty());
    REQUIRE(
        validate_draft("Historical target cost <$3; not current prices. [S1]",
                       evidence)
            .empty());
    REQUIRE(!validate_draft("Historical cost >$3. [S1]", evidence).empty());
    std::string table = "| Attribute | Target |\n|---|---|\n| Cost | <$3 |",
                note = "These are historical 2017 targets, not current prices.";
    evidence = {{"S1", table + "\n" + note}};
    auto attributed =
        attribute_source_copies(table, evidence, {{"", "S1", "", note}});
    REQUIRE(attributed.find("<$3  [S1]") != std::string::npos);
    REQUIRE(attributed.find("**Source caveat:** " + note + " [S1]") !=
            std::string::npos);
    auto changed = attribute_source_copies("| Cost | <$5 |", evidence, {});
    REQUIRE(changed.find("[S1]") == std::string::npos);
    REQUIRE(!validate_draft(changed, evidence).empty());
    std::string nested =
        "## Instructions\n\n**Step 1: Define the population**\n* **Output:** A "
        "population statement. [S1]\n\n**Missing information:**\n\nNo "
        "numerical thresholds are specified. [S1]";
    evidence = {{"S1", "Step 1: Define the population. Output a population "
                       "statement. No numerical thresholds are specified."}};
    REQUIRE(validate_draft(nested, evidence).empty());
    REQUIRE(claim_blocks(nested).at(0).find("Define the population") !=
            std::string::npos);
    REQUIRE(validate_draft("## Profile\n\nThe profile contains these "
                           "attributes:\n\n* Dose target: 100 mg. [S1]",
                           {{"S1", "The profile has a dose target of 100 mg."}})
                .empty());
    json request = {{"version", 1},
                    {"question", "When is launch?"},
                    {"sources",
                     {{{"citation", "S1"},
                       {"title", "Launch"},
                       {"excerpt", "The launch is in 2024."}}}}};
    json multi_request = {{"version", 1},
                          {"question", "Who leads Atlas?"},
                          {"sources",
                           {{{"citation", "S1"},
                             {"title", "Atlas"},
                             {"excerpt", "Mira leads Atlas."}},
                            {{"citation", "S2"},
                             {"title", "Atlas"},
                             {"excerpt", "Mira leads Atlas."}},
                            {{"citation", "S3"},
                             {"title", "Atlas"},
                             {"excerpt", "Mira leads Atlas."}}}}};
    Fake multi{{"S1.1 S2.1 S3.1", "Mira leads Atlas. [S1-S3]", "SUPPORTED"}};
    REQUIRE(grounded_answer(multi, multi_request, 512).at("citations") ==
            json({"S1", "S2", "S3"}));
    Fake retry{{"S1.1", "The launch is in 204. [S1]",
                "The launch is in 2024. [S1]", "SUPPORTED"}};
    auto result = grounded_answer(retry, request, 512);
    REQUIRE(result.at("answer") == "The launch is in 2024. [S1]");
    REQUIRE(result.at("grounding").at("attempts") == 2);
    Fake failed{
        {"S1.1", "The launch is in 204. [S1]", "The launch is in 207. [S1]"}};
    result = grounded_answer(failed, request, 512);
    REQUIRE(result.at("method") == "source-fallback");
    REQUIRE(result.at("answer").get<std::string>().find("2024") !=
            std::string::npos);
    Fake unknown{{"S99.1"}};
    REQUIRE(grounded_answer(unknown, request, 512).at("citations") ==
            json({"S1"}));
    Fake none{{"NONE"}};
    REQUIRE(grounded_answer(none, request, 512).at("citations").empty());
    for (auto verdict : {"UNSUPPORTED", "Probably supported", ""}) {
      Fake f{{verdict}};
      REQUIRE(!verify_support(f, "Orion is approved. [S1]",
                              {{"S1", "Orion is not approved."}}, ""));
    }
    Fake tokenizer;
    auto fitted = fit(tokenizer,
                      {{"S1.1", "S1", "Dose", std::string(6000, 'x')},
                       {"S1.2", "S1", "Duration", "12–24 months"}},
                      "Question\n", 1536);
    REQUIRE(fitted.size() == 1 && fitted[0].id == "S1.2");
    auto units = evidence_units(
        json({{{"citation", "S1"},
               {"title", "Résumé"},
               {"excerpt", "---\na: 2024\n---\n# Étude\n\nDose 100 mg.\n\n## "
                           "Résultat\n\nDurée 12–24 mois."}}}));
    REQUIRE(units.size() == 2 && units[0].heading == "Résumé / Étude" &&
            units[1].heading == "Résumé / Étude / Résultat");
    REQUIRE(words("CAFÉ 東京") == Strings({"café", "東京"}));
    REQUIRE(validate_draft("## Overview [S99]", {{"S1", "A source."}})
                .count("Missing or unknown citation") == 1);
    REQUIRE(validate_draft("## Overview", {{"S1", "A source."}}).empty());
    REQUIRE(validate_draft("[S99]", {{"S1", "A source."}})
                .count("Missing or unknown citation") == 1);
    Fake no_generation;
    const std::string oversized = std::string(6000, 'x') + " 12–24 months";
    json oversized_request = {{"version", 1},
                              {"question", "What is the duration?"},
                              {"sources",
                               {{{"citation", "S1"},
                                 {"title", "Whole evidence"},
                                 {"excerpt", oversized}}}}};
    auto fallback = grounded_answer(no_generation, oversized_request, 512);
    REQUIRE(fallback.at("method") == "source-fallback");
    REQUIRE(fallback.at("answer").get<std::string>().find(oversized) !=
            std::string::npos);
    REQUIRE(no_generation.cursor == 0);
    std::cout << "Native grounding: attribution, numeric fidelity, Unicode, "
                 "retry, fallback, verification and budget checks passed\n";
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
