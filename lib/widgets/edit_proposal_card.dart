import 'package:flutter/material.dart';

import '../services/edit_proposal.dart';
import '../theme/cursor_theme.dart';

class EditProposalCard extends StatelessWidget {
  const EditProposalCard({
    super.key,
    required this.proposal,
    required this.onAccept,
    required this.onReject,
  });

  final EditProposal proposal;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final preview = proposal.newText.length > 600
        ? '${proposal.newText.substring(0, 600)}\n…'
        : proposal.newText;
    final oldPreview = (proposal.oldText ?? '').length > 280
        ? '${proposal.oldText!.substring(0, 280)}\n…'
        : (proposal.oldText ?? '');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CursorColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CursorColors.accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_fix_high, size: 14, color: CursorColors.accentSoft),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  proposal.summary ?? 'Proposed edit',
                  style: TextStyle(
                    color: CursorColors.fgBright,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                proposal.scope.name,
                style: TextStyle(color: CursorColors.fgDim, fontSize: 10),
              ),
            ],
          ),
          if (oldPreview.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('− before', style: TextStyle(color: const Color(0xFFFF8E8E), fontSize: 10)),
            const SizedBox(height: 2),
            SelectableText(
              oldPreview,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: CursorColors.fgMuted,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text('+ after', style: TextStyle(color: const Color(0xFF7DFFB3), fontSize: 10)),
          const SizedBox(height: 2),
          SelectableText(
            preview,
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              color: CursorColors.fgBright,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _Btn(
                  label: 'Reject',
                  color: const Color(0xFFB35A5A),
                  onTap: onReject,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Btn(
                  label: 'Accept',
                  color: const Color(0xFF3D9A5F),
                  onTap: onAccept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: CursorColors.fgBright,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
