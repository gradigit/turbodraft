from __future__ import annotations

import csv
import json
import pathlib
import re
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'bench/prompt_eval/tools/build_human_adjudication_packet.py'
COMPILE_SCRIPT = REPO / 'bench/prompt_eval/tools/compile_human_adjudication_rows.py'
WORKBOOK_SCRIPT = REPO / 'bench/prompt_eval/tools/build_human_adjudication_workbook.py'
WORKBOOK_PARSE_SCRIPT = REPO / 'bench/prompt_eval/tools/parse_human_adjudication_workbook.py'
GUIDED_WORKBOOK_SCRIPT = REPO / 'bench/prompt_eval/tools/build_human_adjudication_guided_workbook.py'
READINESS_SCRIPT = REPO / 'bench/prompt_eval/tools/check_human_adjudication_batch_readiness.py'
DEFICIT_PLANNER_SCRIPT = REPO / 'bench/prompt_eval/tools/plan_human_adjudication_deficit_batch.py'
AI_ASSIST_SCRIPT = REPO / 'bench/prompt_eval/tools/generate_human_adjudication_ai_assist.py'
ASSISTED_WORKBOOK_SCRIPT = REPO / 'bench/prompt_eval/tools/build_human_adjudication_assisted_workbook.py'
ASSISTED_PARSE_SCRIPT = REPO / 'bench/prompt_eval/tools/parse_human_adjudication_assisted_workbook.py'
MATERIALIZE_SCRIPT = REPO / 'bench/prompt_eval/tools/materialize_blind_adjudication_candidates.py'
TIEBREAK_SCRIPT = REPO / 'bench/prompt_eval/tools/build_human_adjudication_tiebreak_workbook.py'


class HumanAdjudicationPacketTests(unittest.TestCase):
    def test_packet_builder_outputs_markdown_and_csv(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            packet = root / 'packet.md'
            answers = root / 'answers.csv'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
                'candidate_a_source': 'seed_a',
                'candidate_b_source': 'seed_b',
                'source_ids': ['seed_a', 'seed_b'],
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(SCRIPT),
                    '--candidates',
                    str(candidates),
                    '--packet-out',
                    str(packet),
                    '--answers-out',
                    str(answers),
                    '--title',
                    'Demo Packet',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            md = packet.read_text(encoding='utf-8')
            self.assertIn('# Demo Packet', md)
            self.assertIn('[ ] A', md)
            self.assertIn('missing_constraint', md)
            self.assertNotIn('seed_a', md)
            self.assertNotIn('seed_b', md)
            with answers.open('r', encoding='utf-8', newline='') as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['case_id'], 'case_demo')
            self.assertEqual(rows[0]['decision'], '')
            self.assertEqual(rows[0]['preset_family'], 'coding')
            self.assertEqual(rows[0]['split'], 'dev')
            self.assertNotIn('candidate_a_source', rows[0])

    def test_packet_builder_can_optionally_show_internal_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            packet = root / 'packet.md'
            answers = root / 'answers.csv'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
                'candidate_a_source': 'seed_a',
                'candidate_b_source': 'seed_b',
                'source_ids': ['seed_a', 'seed_b'],
                'notes': 'A likely stronger.',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(SCRIPT),
                    '--candidates',
                    str(candidates),
                    '--packet-out',
                    str(packet),
                    '--answers-out',
                    str(answers),
                    '--show-internal-metadata',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            md = packet.read_text(encoding='utf-8')
            self.assertIn('Source IDs', md)
            self.assertIn('A likely stronger.', md)



    def test_compile_answers_into_import_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            answers = root / 'answers.csv'
            out = root / 'compiled.jsonl'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
                'candidate_a_source': 'seed_a',
                'candidate_b_source': 'seed_b',
                'source_ids': ['seed_a', 'seed_b'],
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            with answers.open('w', encoding='utf-8', newline='') as fh:
                writer = csv.DictWriter(fh, fieldnames=[
                    'case_id','preset_family','language_tag','split','draft_sha256','candidate_a_text_sha256','candidate_b_text_sha256','candidate_a_source','candidate_b_source','source_ids','rater_id_hashed','decision','blind_decision_raw','blind_confidence_label','quality_a_0_100','quality_b_0_100','confidence_1_5','defect_tags_a','defect_tags_b','notes'
                ])
                writer.writeheader()
                writer.writerow({
                    'case_id': 'case_demo',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'rater_id_hashed': 'r1',
                    'decision': 'A',
                    'blind_decision_raw': 'A',
                    'blind_confidence_label': 'High',
                    'quality_a_0_100': '90',
                    'quality_b_0_100': '55',
                    'confidence_1_5': '4',
                    'defect_tags_a': '',
                    'defect_tags_b': 'verbosity_bloat',
                    'notes': 'A is more precise',
                })
                writer.writerow({
                    'case_id': 'case_demo',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'rater_id_hashed': 'r2',
                    'decision': 'A',
                    'blind_decision_raw': 'A',
                    'blind_confidence_label': 'Medium',
                    'quality_a_0_100': '88',
                    'quality_b_0_100': '52',
                    'confidence_1_5': '5',
                    'defect_tags_a': '',
                    'defect_tags_b': 'missing_constraint|verbosity_bloat',
                    'notes': '',
                })
            proc = subprocess.run([
                'python3', str(COMPILE_SCRIPT),
                '--candidates', str(candidates),
                '--answers', str(answers),
                '--out', str(out),
                '--provenance-source', 'human_panel_batch_01',
                '--provenance-artifact', 'round_01',
                '--min-raters', '2',
            ], capture_output=True, text=True, cwd=REPO)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            rows = [json.loads(line) for line in out.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(len(rows), 3)
            gold = next(row for row in rows if row['item_type'] == 'gold')
            perturb = next(row for row in rows if row['item_type'] == 'perturbation')
            pair = next(row for row in rows if row['item_type'] == 'pairwise')
            self.assertEqual(gold['prompt_text'], 'Structured prompt A')
            self.assertEqual(perturb['prompt_text'], 'Vague prompt B')
            self.assertEqual(pair['expected_winner'], 'A')
            self.assertEqual(gold['rater_count'], 2)
            self.assertIn('verbosity_bloat', perturb['error_tags'])
            self.assertEqual(gold['review_metadata']['source_case_id'], 'case_demo')
            self.assertEqual(len(pair['review_metadata']['blind_vote_details']), 2)
            self.assertEqual(gold['review_metadata']['adjudication_lane'], 'blind_gold')
            self.assertTrue(gold['review_metadata']['lock_eligible'])

    def test_compile_can_merge_multiple_answer_csvs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            answers1 = root / 'answers1.csv'
            answers2 = root / 'answers2.csv'
            out = root / 'compiled.jsonl'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            fieldnames = [
                'case_id','preset_family','language_tag','split','draft_sha256','candidate_a_text_sha256','candidate_b_text_sha256','candidate_a_source','candidate_b_source','source_ids','rater_id_hashed','decision','blind_decision_raw','blind_confidence_label','quality_a_0_100','quality_b_0_100','confidence_1_5','defect_tags_a','defect_tags_b','notes'
            ]
            for path, rater_id, confidence in [(answers1, 'r1', 'High'), (answers2, 'r2', 'Medium')]:
                with path.open('w', encoding='utf-8', newline='') as fh:
                    writer = csv.DictWriter(fh, fieldnames=fieldnames)
                    writer.writeheader()
                    writer.writerow({
                        'case_id': 'case_demo',
                        'preset_family': 'coding',
                        'language_tag': 'en-US',
                        'split': 'dev',
                        'rater_id_hashed': rater_id,
                        'decision': 'A',
                        'blind_decision_raw': 'A',
                        'blind_confidence_label': confidence,
                        'quality_a_0_100': '88',
                        'quality_b_0_100': '52',
                        'confidence_1_5': '5' if confidence == 'High' else '3',
                        'defect_tags_a': '',
                        'defect_tags_b': 'verbosity_bloat',
                        'notes': '',
                    })
            proc = subprocess.run([
                'python3', str(COMPILE_SCRIPT),
                '--candidates', str(candidates),
                '--answers', str(answers1),
                '--answers', str(answers2),
                '--out', str(out),
                '--provenance-source', 'human_panel_batch_01',
                '--provenance-artifact', 'round_01',
                '--min-raters', '2',
            ], capture_output=True, text=True, cwd=REPO)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            payload = json.loads(proc.stdout)
            self.assertEqual(len(payload['answer_sources']), 2)
            rows = [json.loads(line) for line in out.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(len(rows), 3)

    def test_compile_rejects_duplicate_rater_across_answer_sources(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            answers1 = root / 'answers1.csv'
            answers2 = root / 'answers2.csv'
            out = root / 'compiled.jsonl'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            fieldnames = [
                'case_id','preset_family','language_tag','split','draft_sha256','candidate_a_text_sha256','candidate_b_text_sha256','candidate_a_source','candidate_b_source','source_ids','rater_id_hashed','decision','blind_decision_raw','blind_confidence_label','quality_a_0_100','quality_b_0_100','confidence_1_5','defect_tags_a','defect_tags_b','notes'
            ]
            for path in (answers1, answers2):
                with path.open('w', encoding='utf-8', newline='') as fh:
                    writer = csv.DictWriter(fh, fieldnames=fieldnames)
                    writer.writeheader()
                    writer.writerow({
                        'case_id': 'case_demo',
                        'preset_family': 'coding',
                        'language_tag': 'en-US',
                        'split': 'dev',
                        'rater_id_hashed': 'r1',
                        'decision': 'A',
                        'blind_decision_raw': 'A',
                        'blind_confidence_label': 'High',
                        'quality_a_0_100': '88',
                        'quality_b_0_100': '52',
                        'confidence_1_5': '5',
                        'defect_tags_a': '',
                        'defect_tags_b': 'verbosity_bloat',
                        'notes': '',
                    })
            proc = subprocess.run([
                'python3', str(COMPILE_SCRIPT),
                '--candidates', str(candidates),
                '--answers', str(answers1),
                '--answers', str(answers2),
                '--out', str(out),
                '--provenance-source', 'human_panel_batch_01',
                '--provenance-artifact', 'round_01',
                '--min-raters', '2',
            ], capture_output=True, text=True, cwd=REPO)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('duplicate rater_id_hashed', proc.stderr)

    def test_compile_mixed_tie_votes_are_unresolved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            answers = root / 'answers.csv'
            out = root / 'compiled.jsonl'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            with answers.open('w', encoding='utf-8', newline='') as fh:
                writer = csv.DictWriter(fh, fieldnames=[
                    'case_id','preset_family','language_tag','split','rater_id_hashed','decision','quality_a_0_100','quality_b_0_100','confidence_1_5','defect_tags_a','defect_tags_b','notes'
                ])
                writer.writeheader()
                writer.writerow({
                    'case_id': 'case_demo',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'rater_id_hashed': 'r1',
                    'decision': 'A',
                    'quality_a_0_100': '90',
                    'quality_b_0_100': '55',
                    'confidence_1_5': '4',
                    'defect_tags_a': '',
                    'defect_tags_b': '',
                    'notes': '',
                })
                writer.writerow({
                    'case_id': 'case_demo',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'rater_id_hashed': 'r2',
                    'decision': 'Tie',
                    'quality_a_0_100': '80',
                    'quality_b_0_100': '80',
                    'confidence_1_5': '2',
                    'defect_tags_a': '',
                    'defect_tags_b': '',
                    'notes': 'close call',
                })
            proc = subprocess.run([
                'python3', str(COMPILE_SCRIPT),
                '--candidates', str(candidates),
                '--answers', str(answers),
                '--out', str(out),
                '--provenance-source', 'human_panel_batch_01',
                '--provenance-artifact', 'round_01',
                '--min-raters', '2',
            ], capture_output=True, text=True, cwd=REPO)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('unresolved adjudication', proc.stderr)

    def test_workbook_build_and_parse_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'workbook.md'
            parsed = root / 'answers.csv'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A with explicit constraints.',
                'candidate_b': 'Vague prompt B.',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                    '--title', 'Workbook Demo',
                    '--seed', '123',
                    '--rater-label', 'alice',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            text = workbook.read_text(encoding='utf-8')
            self.assertIn('Workbook Demo', text)
            self.assertIn('TD_CASE_META', text)
            self.assertNotIn('Preset family:', text)
            self.assertNotIn('Split target:', text)
            filled = text.replace('- [ ] A', '- [x] A', 1).replace('- [ ] High', '- [x] High', 1).replace('> ', 'clear winner', 1)
            workbook.write_text(filled, encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_PARSE_SCRIPT),
                    '--workbook', str(workbook),
                    '--out', str(parsed),
                    '--rater-id-hashed', 'r1',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            with parsed.open('r', encoding='utf-8', newline='') as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['case_id'], 'case_demo')
            self.assertIn(rows[0]['decision'], {'A', 'B'})
            self.assertEqual(rows[0]['decision_mode'], 'blind_gold')
            self.assertEqual(rows[0]['blind_decision_raw'], 'A')
            self.assertEqual(rows[0]['blind_confidence_label'], 'High')
            self.assertEqual(rows[0]['confidence_1_5'], '5')
            self.assertTrue(rows[0]['notes'])

    def test_workbook_validate_only_reports_incomplete_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'workbook.md'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            proc = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_PARSE_SCRIPT),
                    '--workbook', str(workbook),
                    '--validate-only',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            payload = json.loads(proc.stdout)
            self.assertFalse(payload['ready_for_parse'])
            self.assertEqual(payload['complete_case_count'], 0)
            self.assertIn('Winner must have exactly one checked option', payload['cases'][0]['errors'])

    def test_guided_workbook_build_and_parse_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            guidance = root / 'guidance.json'
            workbook = root / 'guided.md'
            parsed = root / 'answers.csv'
            row = {
                'case_id': 'case_guided',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'sealed_test',
                'draft_prompt': 'Preserve hard constraints without scope drift.',
                'candidate_a': 'Prompt A with explicit acceptance checks.',
                'candidate_b': 'Prompt B with mild ambiguity.',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            guidance.write_text(
                json.dumps(
                    {
                        'case_guided': {
                            'why_it_matters': 'This case checks whether a subtle ambiguity slips through.',
                            'checklist': ['Keep hard constraints explicit', 'Avoid scope drift'],
                            'disqualifiers': ['Drops validation', 'Adds new scope'],
                        }
                    }
                ),
                encoding='utf-8',
            )
            build = subprocess.run(
                [
                    'python3',
                    str(GUIDED_WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--guidance-json', str(guidance),
                    '--workbook-out', str(workbook),
                    '--seed', '7',
                    '--rater-label', 'gamma',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            text = workbook.read_text(encoding='utf-8')
            self.assertIn('guided blind core', text.lower())
            self.assertIn('Quick checklist', text)
            self.assertIn('Disqualifiers to look for', text)
            filled = text.replace('- [ ] B', '- [x] B', 1).replace('- [ ] Medium', '- [x] Medium', 1)
            workbook.write_text(filled, encoding='utf-8')
            parsed_proc = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_PARSE_SCRIPT),
                    '--workbook', str(workbook),
                    '--out', str(parsed),
                    '--rater-id-hashed', 'r-guided',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(parsed_proc.returncode, 0, msg=parsed_proc.stderr + '\n' + parsed_proc.stdout)
            with parsed.open('r', encoding='utf-8', newline='') as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['case_id'], 'case_guided')
            self.assertEqual(rows[0]['decision_mode'], 'guided_blind_core')
            self.assertEqual(rows[0]['blind_decision_raw'], 'B')
            self.assertEqual(rows[0]['blind_confidence_label'], 'Medium')

    def test_parser_rejects_content_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'workbook.md'
            parsed = root / 'answers.csv'
            row = {
                'case_id': 'case_tamper',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Keep the change scoped.',
                'candidate_a': 'Prompt A',
                'candidate_b': 'Prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            text = workbook.read_text(encoding='utf-8').replace('Prompt A', 'Prompt A tampered', 1)
            text = text.replace('- [ ] A', '- [x] A', 1).replace('- [ ] High', '- [x] High', 1)
            workbook.write_text(text, encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_PARSE_SCRIPT),
                    '--workbook', str(workbook),
                    '--out', str(parsed),
                    '--rater-id-hashed', 'r1',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('case content integrity check failed', proc.stderr)

    def test_batch_readiness_reports_case_level_compile_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook1 = root / 'r1.md'
            workbook2 = root / 'r2.md'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            for target, winner in [(workbook1, 'A'), (workbook2, None)]:
                build = subprocess.run(
                    [
                        'python3',
                        str(WORKBOOK_SCRIPT),
                        '--candidates', str(candidates),
                        '--workbook-out', str(target),
                    ],
                    capture_output=True,
                    text=True,
                    cwd=REPO,
                )
                self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
                text = target.read_text(encoding='utf-8')
                if winner:
                    text = text.replace(f'- [ ] {winner}', f'- [x] {winner}', 1).replace('- [ ] High', '- [x] High', 1)
                    target.write_text(text, encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(READINESS_SCRIPT),
                    '--workbook', str(workbook1),
                    '--workbook', str(workbook2),
                    '--require-raters', '2',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            payload = json.loads(proc.stdout)
            self.assertFalse(payload['ready_for_compile'])
            self.assertEqual(payload['per_case']['case_demo']['complete_rater_count'], 1)

    def test_batch_readiness_deduplicates_same_workbook_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'r1.md'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            text = workbook.read_text(encoding='utf-8').replace('- [ ] A', '- [x] A', 1).replace('- [ ] High', '- [x] High', 1)
            workbook.write_text(text, encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(READINESS_SCRIPT),
                    '--workbook', str(workbook),
                    '--workbook', str(workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            payload = json.loads(proc.stdout)
            self.assertEqual(payload['workbook_count'], 1)
            self.assertEqual(payload['per_case']['case_demo']['complete_rater_count'], 1)

    def test_batch_readiness_requires_workbook_ready_for_parse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'dup.md'
            rows = [
                {
                    'case_id': 'case_demo_1',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'draft_prompt': 'Fix the sidebar drag behavior.',
                    'candidate_a': 'Structured prompt A',
                    'candidate_b': 'Vague prompt B',
                },
                {
                    'case_id': 'case_demo_1',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'draft_prompt': 'Refine the product request prompt.',
                    'candidate_a': 'Structured prompt C',
                    'candidate_b': 'Vague prompt D',
                },
            ]
            candidates.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            text = workbook.read_text(encoding='utf-8')
            text = text.replace('- [ ] A', '- [x] A', 2).replace('- [ ] High', '- [x] High', 2)
            workbook.write_text(text, encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(READINESS_SCRIPT),
                    '--workbook', str(workbook),
                    '--require-raters', '1',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            payload = json.loads(proc.stdout)
            self.assertFalse(payload['workbooks'][0]['ready_for_parse'])
            self.assertFalse(payload['ready_for_compile'])

    def test_deficit_planner_prioritizes_sealed_and_missing_language_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            current = root / 'current.jsonl'
            candidates = root / 'candidates.jsonl'
            selected = root / 'selected.jsonl'
            summary = root / 'summary.json'
            current_rows = [
                {
                    'id': 'pair_en_dev',
                    'item_type': 'pairwise',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                }
            ]
            current.write_text(''.join(json.dumps(row) + '\n' for row in current_rows), encoding='utf-8')
            candidate_rows = [
                {
                    'case_id': 'case_en_dev',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'dev',
                    'draft_prompt': 'A',
                    'candidate_a': 'A1',
                    'candidate_b': 'A2',
                },
                {
                    'case_id': 'case_ko_sealed',
                    'preset_family': 'review',
                    'language_tag': 'ko-KR',
                    'split': 'sealed_test',
                    'draft_prompt': 'B',
                    'candidate_a': 'B1',
                    'candidate_b': 'B2',
                },
            ]
            candidates.write_text(''.join(json.dumps(row) + '\n' for row in candidate_rows), encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(DEFICIT_PLANNER_SCRIPT),
                    '--current', str(current),
                    '--candidates', str(candidates),
                    '--out-jsonl', str(selected),
                    '--summary-out', str(summary),
                    '--max-cases', '1',
                    '--pairwise-target', '5',
                    '--sealed-target', '2',
                    '--family-target', '2',
                    '--language-target', '2',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            selected_rows = [json.loads(line) for line in selected.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(len(selected_rows), 1)
            self.assertEqual(selected_rows[0]['case_id'], 'case_ko_sealed')
            payload = json.loads(summary.read_text(encoding='utf-8'))
            self.assertEqual(payload['selected_case_ids'], ['case_ko_sealed'])

    def test_deficit_planner_excludes_existing_case_ids(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            current = root / 'current.jsonl'
            candidates = root / 'candidates.jsonl'
            selected = root / 'selected.jsonl'
            current_rows = [
                {
                    'id': 'pair_1',
                    'item_type': 'pairwise',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'sealed_test',
                    'review_metadata': {'source_case_id': 'case_existing'},
                }
            ]
            current.write_text(''.join(json.dumps(row) + '\n' for row in current_rows), encoding='utf-8')
            candidate_rows = [
                {
                    'case_id': 'case_existing',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'sealed_test',
                    'draft_prompt': 'A',
                    'candidate_a': 'A1',
                    'candidate_b': 'A2',
                },
                {
                    'case_id': 'case_new',
                    'preset_family': 'review',
                    'language_tag': 'ko-KR',
                    'split': 'sealed_test',
                    'draft_prompt': 'B',
                    'candidate_a': 'B1',
                    'candidate_b': 'B2',
                },
            ]
            candidates.write_text(''.join(json.dumps(row) + '\n' for row in candidate_rows), encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(DEFICIT_PLANNER_SCRIPT),
                    '--current', str(current),
                    '--candidates', str(candidates),
                    '--out-jsonl', str(selected),
                    '--max-cases', '2',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            selected_rows = [json.loads(line) for line in selected.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual([row['case_id'] for row in selected_rows], ['case_new'])

    def test_deficit_planner_does_not_reselect_id_only_case(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            selected = root / 'selected.jsonl'
            candidate_rows = [
                {
                    'id': 'case_from_id',
                    'preset_family': 'coding',
                    'language_tag': 'en-US',
                    'split': 'sealed_test',
                    'draft_prompt': 'A',
                    'candidate_a': 'A1',
                    'candidate_b': 'A2',
                }
            ]
            candidates.write_text(''.join(json.dumps(row) + '\n' for row in candidate_rows), encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(DEFICIT_PLANNER_SCRIPT),
                    '--candidates', str(candidates),
                    '--out-jsonl', str(selected),
                    '--max-cases', '3',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            selected_rows = [json.loads(line) for line in selected.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(len(selected_rows), 1)
            payload = json.loads(proc.stdout)
            self.assertEqual(payload['selected_case_ids'], ['case_from_id'])

    def test_ai_assist_appendix_simulated(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            workbook = root / 'workbook.md'
            appendix = root / 'appendix.md'
            appendix_jsonl = root / 'appendix.jsonl'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A with explicit constraints and verification.',
                'candidate_b': 'Vague prompt B.',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(workbook),
                    '--seed', '1',
                    '--rater-label', 'bob',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            proc = subprocess.run(
                [
                    'python3',
                    str(AI_ASSIST_SCRIPT),
                    '--workbook', str(workbook),
                    '--appendix-out', str(appendix),
                    '--jsonl-out', str(appendix_jsonl),
                    '--simulate-no-provider',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            md = appendix.read_text(encoding='utf-8')
            self.assertIn('AI Assist Appendix', md)
            self.assertIn('Current assist model:', md)
            self.assertIn('AI pick:', md)
            rows = [json.loads(line) for line in appendix_jsonl.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(len(rows), 1)
            self.assertIn(rows[0]['winner'], {'A', 'B', 'Tie'})
            self.assertIn(rows[0]['canonical_winner'], {'A', 'B', 'Tie'})
            self.assertEqual(rows[0]['provider_label'], 'Simulated AI')

    def test_build_and_parse_assisted_workbook(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            blind_workbook = root / 'blind_workbook.md'
            appendix = root / 'appendix.md'
            appendix_jsonl = root / 'appendix.jsonl'
            assisted_workbook = root / 'assisted_workbook.md'
            parsed = root / 'parsed.csv'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A with explicit constraints and verification.',
                'candidate_b': 'Vague prompt B.',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            build = subprocess.run(
                [
                    'python3',
                    str(WORKBOOK_SCRIPT),
                    '--candidates', str(candidates),
                    '--workbook-out', str(blind_workbook),
                    '--seed', '1',
                    '--rater-label', 'bob',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(build.returncode, 0, msg=build.stderr + '\n' + build.stdout)
            assist = subprocess.run(
                [
                    'python3',
                    str(AI_ASSIST_SCRIPT),
                    '--workbook', str(blind_workbook),
                    '--appendix-out', str(appendix),
                    '--jsonl-out', str(appendix_jsonl),
                    '--simulate-no-provider',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(assist.returncode, 0, msg=assist.stderr + '\n' + assist.stdout)
            assisted = subprocess.run(
                [
                    'python3',
                    str(ASSISTED_WORKBOOK_SCRIPT),
                    '--blind-workbook', str(blind_workbook),
                    '--assist-jsonl', str(appendix_jsonl),
                    '--workbook-out', str(assisted_workbook),
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(assisted.returncode, 0, msg=assisted.stderr + '\n' + assisted.stdout)
            md = assisted_workbook.read_text(encoding='utf-8')
            self.assertIn('AI-assisted expansion lane', md)
            self.assertIn('AI assessment', md)
            self.assertIn('Relation to AI:', md)

            filled = md.replace('- [ ] Agree', '- [x] Agree', 1)
            ai_pick_match = re.search(r'- AI pick: (A|B|Tie|BothBad)', filled)
            self.assertIsNotNone(ai_pick_match)
            assert ai_pick_match is not None
            ai_pick = ai_pick_match.group(1)
            filled = filled.replace(f'- [ ] {ai_pick}', f'- [x] {ai_pick}', 1)
            filled = filled.replace('- [ ] Medium', '- [x] Medium', 1)
            assisted_workbook.write_text(filled, encoding='utf-8')

            parsed_proc = subprocess.run(
                [
                    'python3',
                    str(ASSISTED_PARSE_SCRIPT),
                    '--workbook', str(assisted_workbook),
                    '--out', str(parsed),
                    '--rater-id-hashed', 'r1',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(parsed_proc.returncode, 0, msg=parsed_proc.stderr + '\n' + parsed_proc.stdout)
            with parsed.open('r', encoding='utf-8', newline='') as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['case_id'], 'case_demo')
            self.assertEqual(rows[0]['decision_mode'], 'assisted_expansion')
            self.assertEqual(rows[0]['assist_relation'], 'agree')
            self.assertEqual(rows[0]['assist_model_label'], 'Simulated AI')

    def test_materialize_blind_candidates_strips_sensitive_fields_and_rewrites_ids(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            source = root / 'source.jsonl'
            blind = root / 'blind.jsonl'
            mapping = root / 'mapping.jsonl'
            row = {
                'case_id': 'internal_case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'A',
                'candidate_b': 'B',
                'candidate_a_source': 'seed_a',
                'candidate_b_source': 'seed_b',
                'source_ids': ['seed_a', 'seed_b'],
                'notes': 'internal only',
                'internal_expected_winner_seed': 'B',
            }
            source.write_text(json.dumps(row) + '\n', encoding='utf-8')
            proc = subprocess.run(
                [
                    'python3',
                    str(MATERIALIZE_SCRIPT),
                    '--source', str(source),
                    '--blind-out', str(blind),
                    '--mapping-out', str(mapping),
                    '--batch-label', 'batchblind',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            blind_rows = [json.loads(line) for line in blind.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(blind_rows[0]['case_id'], 'batchblind_en_001')
            self.assertNotIn('candidate_a_source', blind_rows[0])
            self.assertNotIn('internal_expected_winner_seed', blind_rows[0])
            mapping_rows = [json.loads(line) for line in mapping.read_text(encoding='utf-8').splitlines() if line.strip()]
            self.assertEqual(mapping_rows[0]['source_case_id'], 'internal_case_demo')
            self.assertEqual(mapping_rows[0]['internal_expected_winner_seed'], 'B')

    def test_build_tiebreak_workbook_for_disagreement_case(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            candidates = root / 'candidates.jsonl'
            answers1 = root / 'answers1.csv'
            answers2 = root / 'answers2.csv'
            workbook = root / 'tiebreak.md'
            row = {
                'case_id': 'case_demo',
                'preset_family': 'coding',
                'language_tag': 'en-US',
                'split': 'dev',
                'draft_prompt': 'Fix the sidebar drag behavior.',
                'candidate_a': 'Structured prompt A',
                'candidate_b': 'Vague prompt B',
            }
            candidates.write_text(json.dumps(row) + '\n', encoding='utf-8')
            fieldnames = [
                'case_id', 'preset_family', 'language_tag', 'split', 'rater_id_hashed', 'decision',
                'blind_decision_raw', 'blind_confidence_label', 'quality_a_0_100', 'quality_b_0_100',
                'confidence_1_5', 'defect_tags_a', 'defect_tags_b', 'notes'
            ]
            for path, decision, confidence in [(answers1, 'A', 'High'), (answers2, 'Tie', 'Low')]:
                with path.open('w', encoding='utf-8', newline='') as fh:
                    writer = csv.DictWriter(fh, fieldnames=fieldnames)
                    writer.writeheader()
                    writer.writerow({
                        'case_id': 'case_demo',
                        'preset_family': 'coding',
                        'language_tag': 'en-US',
                        'split': 'dev',
                        'rater_id_hashed': path.stem,
                        'decision': decision,
                        'blind_decision_raw': decision,
                        'blind_confidence_label': confidence,
                        'quality_a_0_100': '60',
                        'quality_b_0_100': '40',
                        'confidence_1_5': '1' if confidence == 'Low' else '5',
                        'defect_tags_a': '',
                        'defect_tags_b': '',
                        'notes': '',
                    })
            proc = subprocess.run(
                [
                    'python3',
                    str(TIEBREAK_SCRIPT),
                    '--candidates', str(candidates),
                    '--answers', str(answers1), str(answers2),
                    '--workbook-out', str(workbook),
                    '--seed', '7',
                    '--rater-label', 'tb',
                ],
                capture_output=True,
                text=True,
                cwd=REPO,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + '\n' + proc.stdout)
            text = workbook.read_text(encoding='utf-8')
            self.assertIn('Tie-break', text)
            self.assertIn('## Case 01', text)

if __name__ == '__main__':
    unittest.main()
