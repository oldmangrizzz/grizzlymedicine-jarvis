#pragma once

#include <string>
#include <vector>

namespace jarvis::abstention {

enum class AuditStatus { Pass, Gap };

struct CognitiveSurfaceAudit {
    std::string organ;
    std::string entry_point;
    AuditStatus status = AuditStatus::Gap;
    std::string detail;
    std::string threshold;
};

std::vector<CognitiveSurfaceAudit> discipline_audit();
bool audit_has_gaps(const std::vector<CognitiveSurfaceAudit>& report);
std::vector<CognitiveSurfaceAudit> audit_gaps(const std::vector<CognitiveSurfaceAudit>& report);

} // namespace jarvis::abstention
